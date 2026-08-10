defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{CodexSessionTailer, EngineLogTailer}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @log_buffer_max_lines 500

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign_drawer_defaults()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case Map.get(params, "issue") do
      id when is_binary(id) and id != "" ->
        {:noreply, maybe_open_issue_from_query(socket, String.trim(id))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> maybe_poll_log_tails()}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("open_drawer", %{"issue_identifier" => id}, socket) do
    {:noreply, open_drawer_for(socket, id)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign_drawer_defaults(socket)}
  end

  def handle_event("drawer_tab", %{"tab" => tab}, socket) do
    drawer_tab =
      case tab do
        "codex" -> :codex
        _ -> :engine
      end

    {:noreply, assign(socket, :drawer_tab, drawer_tab)}
  end

  def handle_event("toggle_stick_bottom", _params, socket) do
    {:noreply, assign(socket, :stick_bottom, !socket.assigns.stick_bottom)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
        <div class="flash flash-error" role="alert"><%= msg %></div>
      <% end %>
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running} data-issue={entry.issue_identifier}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="open_drawer"
                          phx-value-issue_identifier={entry.issue_identifier}
                        >
                          Logs
                        </button>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked} data-issue={entry.issue_identifier}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="open_drawer"
                          phx-value-issue_identifier={entry.issue_identifier}
                        >
                          Logs
                        </button>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section :if={@payload[:parked] not in [nil, []]} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Parked</h2>
              <p class="section-copy">Issues retained after leaving active work (Human Review / Merging).</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 680px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>State</th>
                  <th>Session</th>
                  <th>Workspace</th>
                  <th>Parked at</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.parked} data-issue={entry.issue_identifier}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= entry.issue_identifier %></span>
                      <button
                        type="button"
                        class="subtle-button"
                        phx-click="open_drawer"
                        phx-value-issue_identifier={entry.issue_identifier}
                      >
                        Logs
                      </button>
                      <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                    </div>
                  </td>
                  <td>
                    <span class={state_badge_class(entry.linear_state || "Parked")}>
                      <%= entry.linear_state || "Parked" %>
                    </span>
                  </td>
                  <td>
                    <%= if entry.session_id do %>
                      <button
                        type="button"
                        class="subtle-button"
                        data-label="Copy ID"
                        data-copy={entry.session_id}
                        onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                      >
                        Copy ID
                      </button>
                    <% else %>
                      <span class="muted">n/a</span>
                    <% end %>
                  </td>
                  <td class="mono"><%= entry.workspace_path || "n/a" %></td>
                  <td class="mono"><%= entry.parked_at || "n/a" %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying} data-issue={entry.issue_identifier}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="open_drawer"
                          phx-value-issue_identifier={entry.issue_identifier}
                        >
                          Logs
                        </button>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>

      <%= if @drawer_issue do %>
        <div class="drawer-backdrop" phx-click="close_drawer"></div>
        <aside
          id="log-drawer"
          class="log-drawer"
          phx-window-keydown="close_drawer"
          phx-key="Escape"
        >
          <header class="log-drawer-header">
            <div class="log-drawer-heading">
              <h2 class="log-drawer-title"><%= @drawer_issue.issue_identifier %></h2>
              <div class="log-drawer-meta">
                <span class={if(@drawer_issue.parked?, do: "state-badge state-badge-warning", else: "state-badge state-badge-active")}>
                  <%= if @drawer_issue.parked?, do: "Parked", else: "Live" %>
                </span>
                <%= if @drawer_issue.linear_state do %>
                  <span class={state_badge_class(@drawer_issue.linear_state)}>
                    <%= @drawer_issue.linear_state %>
                  </span>
                <% end %>
              </div>
              <%= if @drawer_issue.session_id do %>
                <p class="log-drawer-sub mono">
                  session:
                  <button
                    type="button"
                    class="subtle-button"
                    data-label="Copy session"
                    data-copy={@drawer_issue.session_id}
                    onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                  >
                    Copy session
                  </button>
                </p>
              <% end %>
              <%= if @drawer_issue.workspace_path do %>
                <p class="log-drawer-sub mono muted"><%= @drawer_issue.workspace_path %></p>
              <% end %>
            </div>
            <button type="button" class="secondary" phx-click="close_drawer">Close</button>
          </header>

          <div class="drawer-tabs">
            <button
              type="button"
              class={if(@drawer_tab == :engine, do: "drawer-tab drawer-tab-active", else: "drawer-tab")}
              phx-click="drawer_tab"
              phx-value-tab="engine"
            >
              Engine
            </button>
            <button
              type="button"
              class={if(@drawer_tab == :codex, do: "drawer-tab drawer-tab-active", else: "drawer-tab")}
              phx-click="drawer_tab"
              phx-value-tab="codex"
            >
              Codex
            </button>
            <button
              type="button"
              class="subtle-button drawer-stick-toggle"
              phx-click="toggle_stick_bottom"
            >
              <%= if @stick_bottom, do: "Stick bottom: on", else: "Stick bottom: off" %>
            </button>
          </div>

          <pre
            id="log-pane"
            class="log-pane"
            phx-hook="LogStickBottom"
            data-stick-bottom={to_string(@stick_bottom)}
          ><%= log_pane_text(@drawer_issue, @drawer_tab, @engine_lines, @codex_lines) %></pre>
        </aside>
      <% end %>
    </section>
    """
  end

  defp log_pane_text(issue, :engine, [], _codex_lines) do
    "No matching engine log lines for #{issue.issue_identifier} yet."
  end

  defp log_pane_text(issue, :codex, _engine_lines, []) do
    cond do
      issue.session_id in [nil, "", "n/a"] ->
        "No Codex session_id for this run."

      true ->
        "Codex session transcript not found or empty for session #{issue.session_id}."
    end
  end

  defp log_pane_text(_issue, tab, engine_lines, codex_lines) do
    Enum.join(visible_lines(tab, engine_lines, codex_lines), "\n")
  end

  defp assign_drawer_defaults(socket) do
    socket
    |> assign(:drawer_issue, nil)
    |> assign(:drawer_tab, :engine)
    |> assign(:engine_lines, [])
    |> assign(:codex_lines, [])
    |> assign(:stick_bottom, true)
    |> assign(:engine_follow, nil)
    |> assign(:codex_follow, nil)
  end

  defp maybe_open_issue_from_query(socket, id) do
    if issue_in_payload?(socket.assigns.payload, id) do
      open_drawer_for(socket, id)
    else
      put_flash(socket, :error, "Issue not in live or parked index")
    end
  end

  defp issue_in_payload?(payload, id) when is_binary(id) do
    Enum.any?([:running, :blocked, :retrying, :parked], fn key ->
      Enum.any?(payload[key] || [], fn entry ->
        Map.get(entry, :issue_identifier) == id
      end)
    end)
  end

  defp open_drawer_for(socket, id) when is_binary(id) do
    meta = resolve_issue_meta(socket.assigns.payload, id)
    engine = EngineLogTailer.initial_lines(id, max_lines: @log_buffer_max_lines)
    engine_follow = EngineLogTailer.follow_state(id)

    codex_opts = codex_sessions_opts()

    {codex_lines, codex_follow} =
      case CodexSessionTailer.resolve_path(meta.session_id, codex_opts) do
        {:ok, path} ->
          {CodexSessionTailer.readable_lines(path, codex_opts), CodexSessionTailer.follow_state(path)}

        {:error, _} ->
          {[], nil}
      end

    socket
    |> assign(:drawer_issue, meta)
    |> assign(:drawer_tab, :engine)
    |> assign(:engine_lines, engine)
    |> assign(:codex_lines, Enum.take(codex_lines, -@log_buffer_max_lines))
    |> assign(:engine_follow, engine_follow)
    |> assign(:codex_follow, codex_follow)
    |> assign(:stick_bottom, true)
  end

  defp maybe_poll_log_tails(%{assigns: %{drawer_issue: nil}} = socket), do: socket

  defp maybe_poll_log_tails(socket) do
    {engine_lines, engine_follow} =
      case socket.assigns.engine_follow do
        nil ->
          {socket.assigns.engine_lines, nil}

        follow ->
          {new_lines, next_follow} = EngineLogTailer.poll(follow)
          {append_trimmed(socket.assigns.engine_lines, new_lines), next_follow}
      end

    {codex_lines, codex_follow} =
      case socket.assigns.codex_follow do
        nil ->
          {socket.assigns.codex_lines, nil}

        follow ->
          {new_lines, next_follow} = CodexSessionTailer.poll(follow)
          {append_trimmed(socket.assigns.codex_lines, new_lines), next_follow}
      end

    socket
    |> assign(:engine_lines, engine_lines)
    |> assign(:codex_lines, codex_lines)
    |> assign(:engine_follow, engine_follow)
    |> assign(:codex_follow, codex_follow)
  end

  defp append_trimmed(existing, new_lines) when new_lines == [], do: existing

  defp append_trimmed(existing, new_lines) do
    existing
    |> Kernel.++(new_lines)
    |> Enum.take(-@log_buffer_max_lines)
  end

  defp visible_lines(:codex, _engine_lines, codex_lines), do: codex_lines
  defp visible_lines(_tab, engine_lines, _codex_lines), do: engine_lines

  defp resolve_issue_meta(payload, id) when is_binary(id) do
    parked = Enum.find(payload[:parked] || [], &(&1.issue_identifier == id))
    running = Enum.find(payload[:running] || [], &(&1.issue_identifier == id))
    blocked = Enum.find(payload[:blocked] || [], &(&1.issue_identifier == id))
    retrying = Enum.find(payload[:retrying] || [], &(&1.issue_identifier == id))

    cond do
      running ->
        %{
          issue_identifier: id,
          session_id: Map.get(running, :session_id),
          parked?: false,
          linear_state: Map.get(running, :state),
          workspace_path: Map.get(running, :workspace_path)
        }

      blocked ->
        %{
          issue_identifier: id,
          session_id: Map.get(blocked, :session_id),
          parked?: false,
          linear_state: Map.get(blocked, :state),
          workspace_path: Map.get(blocked, :workspace_path)
        }

      retrying ->
        %{
          issue_identifier: id,
          session_id: (parked && Map.get(parked, :session_id)) || Map.get(retrying, :session_id),
          parked?: not is_nil(parked),
          linear_state: (parked && Map.get(parked, :linear_state)) || nil,
          workspace_path:
            Map.get(retrying, :workspace_path) || (parked && Map.get(parked, :workspace_path))
        }

      parked ->
        %{
          issue_identifier: id,
          session_id: Map.get(parked, :session_id),
          parked?: true,
          linear_state: Map.get(parked, :linear_state),
          workspace_path: Map.get(parked, :workspace_path)
        }

      true ->
        %{
          issue_identifier: id,
          session_id: nil,
          parked?: false,
          linear_state: nil,
          workspace_path: nil
        }
    end
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp codex_sessions_opts do
    case Application.get_env(:symphony_elixir, :codex_sessions_root) do
      root when is_binary(root) and root != "" -> [sessions_root: root]
      _ -> []
    end
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry", "review", "parked", "merging"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
