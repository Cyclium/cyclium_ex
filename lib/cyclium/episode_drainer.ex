defmodule Cyclium.EpisodeDrainer do
  @moduledoc """
  Hands this node's in-flight episodes to recovery, in bulk, when the node
  shuts down.

  A graceful stop (a deploy's SIGTERM) gives the VM a few seconds. Left to
  themselves, every running `Cyclium.EpisodeTask` would notice its shutdown
  EXIT at its next step boundary and write its own hand-off — a status
  update, a claim release, a journal step — a dozen episodes contending for a
  connection pool that is itself draining, with the ones still mid-step
  (usually an LLM call) getting no chance at all before the task supervisor
  kills them.

  So the hand-off is done once, here, for all of them. This process sits in
  `Cyclium.Supervisor` *after* `Cyclium.EpisodeSupervisor`, which means it is
  terminated *before* the episode tasks are (a supervisor stops children in
  reverse start order). Its `terminate/2` reads the running episodes off
  `Cyclium.EpisodeProcessRegistry` — every task registers itself once it holds
  its claim — and issues three statements for the lot:

    1. `UPDATE cyclium_episodes SET phase = 'interrupted'` for every id still
       `:running`. The row stays running; `Cyclium.Recovery.sweep/1` treats the
       phase as stale at once, and the expectation's `recovery_policy` decides.
    2. One `UPDATE` failing this node's work claims on those episodes, so the
       recovering node can re-acquire them without waiting for the lease.
    3. One `INSERT` of an `:observation` step per episode
       (`%{"event" => "interrupted"}`) — the marker a step feed renders as
       "interrupted, will resume shortly" — numbered from one `MAX(step_no)`
       query over all of them.

  Then it broadcasts `episode.step_journaled` and `episode.interrupted` per
  episode (in-memory, no I/O) and sends each task `:cyclium_drained`, which the
  runner's loop takes at its next step boundary as "already handed off — stop,
  write nothing". A task killed mid-step never reaches that boundary, and does
  not need to: its row was already marked in step 1.

  Each statement is best-effort: a failure is logged and the next one still
  runs, so a pool timeout on the journal insert cannot cost the phase stamp
  that recovery depends on.

  `interrupt/1` is the same hand-off for an explicit list, used by the runner
  for a single episode when it receives a shutdown EXIT with no drainer having
  run first (a host that embeds the runner without `Cyclium.Supervisor`).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Cyclium.Schemas.Episode
  alias Cyclium.Schemas.EpisodeStep
  alias Cyclium.Schemas.WorkClaim

  @registry Cyclium.EpisodeProcessRegistry

  # Long enough for the three statements against a draining pool; the
  # supervisor gives up on us after this and moves on to the tasks.
  @shutdown_ms 15_000

  @typedoc "What the hand-off needs to know about one episode."
  @type entry :: %{
          id: String.t(),
          dedupe_key: String.t() | nil,
          actor_id: String.t(),
          expectation_id: String.t() | nil,
          trigger_ref: map() | nil,
          conversation_id: String.t() | nil,
          workflow_instance_id: String.t() | nil,
          workflow_step_id: String.t() | nil
        }

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @shutdown_ms,
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Without this the supervisor's shutdown exit kills us outright and
    # `terminate/2` never runs.
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(reason, _state) do
    case drain_running() do
      {:ok, 0} ->
        :ok

      {:ok, n} ->
        Logger.info(
          "Cyclium.EpisodeDrainer: handed #{n} running episode(s) to recovery (#{inspect(reason)})"
        )
    end

    :ok
  end

  @doc """
  Register the calling episode task as running `episode`, so a drain can find
  it. Called by `Cyclium.EpisodeTask` once it holds its claim; the entry goes
  away with the process. A no-op when the registry is not running.
  """
  @spec register(Episode.t()) :: :ok
  def register(%Episode{} = episode) do
    _ = Registry.register(@registry, episode.id, entry(episode))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The hand-off entry for an episode."
  @spec entry(Episode.t()) :: entry()
  def entry(%Episode{} = episode) do
    %{
      id: episode.id,
      dedupe_key: episode.dedupe_key,
      actor_id: episode.actor_id,
      expectation_id: episode.expectation_id,
      trigger_ref: episode.trigger_ref,
      conversation_id: episode.conversation_id,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    }
  end

  @doc "Every episode task running on this node, as `{pid, entry}`."
  @spec running() :: [{pid(), entry()}]
  def running do
    Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  Hand every running episode on this node to recovery and tell its task to
  stop. Returns `{:ok, count}`. Public so a host with its own shutdown hook
  can call it earlier than the supervisor would.
  """
  @spec drain_running() :: {:ok, non_neg_integer()}
  def drain_running do
    case running() do
      [] ->
        {:ok, 0}

      procs ->
        {:ok, n} = interrupt(Enum.map(procs, fn {_pid, entry} -> entry end))
        Enum.each(procs, fn {pid, _entry} -> send(pid, :cyclium_drained) end)
        {:ok, n}
    end
  end

  @doc """
  The hand-off for a given list of episodes: phase `"interrupted"`, claims
  released, one journal marker each, then the broadcasts. Three statements
  however long the list. Does not notify the tasks — `drain_running/0` does.
  """
  @spec interrupt([entry()]) :: {:ok, non_neg_integer()}
  def interrupt([]), do: {:ok, 0}

  def interrupt(entries) when is_list(entries) do
    now = DateTime.utc_now()
    ids = Enum.map(entries, & &1.id)

    safely("mark interrupted", fn -> mark_interrupted(ids) end)
    safely("release claims", fn -> release_claims(entries, now) end)
    steps = safely("journal markers", fn -> journal_markers(entries, ids, now) end) || %{}

    Enum.each(entries, &broadcast(&1, Map.get(steps, &1.id)))

    {:ok, length(entries)}
  end

  # 1. The phase stamp recovery keys on. Only rows still running: an episode
  # that converged between the registry read and this statement is done, and
  # must not be re-labelled.
  defp mark_interrupted(ids) do
    from(e in Episode, where: e.id in ^ids and e.status == :running)
    |> Cyclium.repo().update_all(set: [phase: "interrupted"])
  end

  # 2. Claims. One statement when the claims backend is the Ecto one (the only
  # backend that ships); otherwise through the gate, one key at a time.
  defp release_claims(entries, now) do
    keys = entries |> Enum.map(& &1.dedupe_key) |> Enum.reject(&is_nil/1)
    node = Cyclium.NodeIdentity.name()
    detail = %{"reason" => "interrupted", "node" => node}

    cond do
      keys == [] ->
        :ok

      Application.get_env(:cyclium, :work_claims) == Cyclium.WorkClaims.EctoClaims ->
        from(c in WorkClaim,
          where: c.dedupe_key in ^keys and c.owner_node == ^node and c.state == :claimed
        )
        |> Cyclium.repo().update_all(
          set: [
            state: :failed,
            finished_at: DateTime.truncate(now, :second),
            error_detail: detail
          ]
        )

      true ->
        Enum.each(keys, &Cyclium.WorkClaims.gate_fail(&1, node, detail))
    end
  end

  # 3. One observation step per episode, numbered after each one's last step.
  # Returns `%{episode_id => step_no}` for the broadcasts.
  defp journal_markers(entries, ids, now) do
    last_step_nos =
      from(s in EpisodeStep,
        where: s.episode_id in ^ids,
        group_by: s.episode_id,
        select: {s.episode_id, max(s.step_no)}
      )
      |> Cyclium.repo().all()
      |> Map.new()

    node = Cyclium.NodeIdentity.name()

    rows =
      Enum.map(entries, fn entry ->
        %{
          id: Ecto.UUID.generate(),
          episode_id: entry.id,
          step_no: Map.get(last_step_nos, entry.id, 0) + 1,
          kind: :observation,
          result_ref: %{"event" => "interrupted", "node" => node},
          created_at: now
        }
      end)

    {_count, _} = Cyclium.repo().insert_all(EpisodeStep, rows)

    Map.new(rows, &{&1.episode_id, &1.step_no})
  end

  defp broadcast(entry, step_no) do
    if step_no do
      Cyclium.Bus.broadcast("episode.step_journaled", %{
        episode_id: entry.id,
        actor_id: entry.actor_id,
        conversation_id: entry.conversation_id,
        step_no: step_no,
        kind: :observation,
        tool_name: nil,
        error_class: nil,
        cost_tokens: nil
      })
    end

    Cyclium.Bus.broadcast("episode.interrupted", %{
      episode_id: entry.id,
      actor_id: entry.actor_id,
      conversation_id: entry.conversation_id,
      expectation_id: entry.expectation_id,
      trigger_ref: entry.trigger_ref,
      status: :running,
      phase: "interrupted",
      workflow_instance_id: entry.workflow_instance_id,
      workflow_step_id: entry.workflow_step_id
    })
  end

  # A shutdown-time write that fails must not stop the next one: the phase
  # stamp is what recovery needs, the marker is what a reader wants, and
  # neither should be lost to the other's pool timeout.
  defp safely(label, fun) do
    fun.()
  rescue
    e ->
      Logger.error(
        "Cyclium.EpisodeDrainer: #{label} failed — " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  catch
    kind, reason ->
      Logger.error(
        "Cyclium.EpisodeDrainer: #{label} failed — " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      nil
  end
end
