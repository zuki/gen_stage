defmodule DynamicSupervisor do
  @moduledoc ~S"""
  A supervisor that dynamically supervises and manages children.

  A supervisor is a process which supervises other processes, called
  child processes. Different from the regular `Supervisor`,
  `DynamicSupervisor` was designed to start, manage and supervise
  these children dynamically.

  **Note**: due to a limitation in Erlang OTP, `DynamicSupervisor`
  currently cannot be used as the root supervisor in your supervision
  tree if you are planning to perform hot-code upgrades. We hope this
  issue is addressed in upcoming OTP releases. For now, it is
  recommended to define the dynamic supervisor as a child of a regular
  supervisor.

  ## Example

  Before we start our dymamic supervisor, let's first build an agent
  that represents a stack. That's the process we will start dynamically:

      defmodule Stack do
        def start_link(state) do
          Agent.start_link(fn -> state end, opts)
        end

        def pop(pid) do
          Agent.get_and_update(pid, fn [h|t] -> {h, t} end)
        end

        def push(pid, h) do
          Agent.cast(fn t -> [h|t] end)
        end
      end

  Now let's start our dynamic supervisor. Similar to a regular
  supervisor, the dynamic supervisor expects a list of child
  specifications on start. Different from regular supervisors,
  this list must contain only one item. The child specified in
  the list won't be started alongside the supervisor, instead,
  the child specification will be used as a template for all
  future supervisor children.

  Let's give it a try:

      # Import helpers for defining supervisors
      import Supervisor.Spec

      # We are going to supervise the Stack server which
      # will be started with a single argument [:hello]
      # and the default name of :sup_stack.
      children = [
        worker(Stack, [])
      ]

      # Start the supervisor with our template
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

  With the supervisor up and running, let's start our first
  children with `DynamicSupervisor.start_child/2`. `start_child/2`
  expects the supervisor PID and a list of arguments. Let's start
  our child with a default stack of `[:hello]`:

      {:ok, stack} = DynamicSupervisor.start_child(sup, [[:hello]])

  Now let's use the stack:

      Stack.pop(stack)
      #=> :hello

      Stack.push(stack, :world)
      #=> :ok

      Stack.pop(stack)
      #=> :world

  However, there is a bug in our stack agent. If we call `:pop` and
  the stack is empty, it is going to crash because no clause matches.
  Let's try it:

      Stack.pop(stack)
      ** (exit) exited in: GenServer.call(#PID<...>, ..., 5000)

  Since the stack is being supervised, the supervisor will automatically
  start a new agent, with the same default stack of `[:hello]` we have
  specified before. However, if we try to access it with the same PID,
  we will get an error:

      Stack.pop(stack)
      ** (exit) exited in: GenServer.call(#PID<...>, ..., 5000)
         ** (EXIT) no process

  Remember, the agent process for the previous stack is gone. The
  supervisor started a new stack but it has a new PID. For now,
  let's use `DynamicSupervisor.children/1` to fetch the new PID:

      [stack] = DynamicSupervisor.children(sup)
      Stack.pop(stack) #=> :hello

  In practice though, it is unlikely we would use `children/1`.
  When we are managing thousands up to million of processes, we
  must find more efficient ways to retrieve processes. We have a
  couple options.

  The first option is to ask if we really want the stack to be
  automatically restarted. If not, we can choose another restart
  mode for the worker. For example:

      worker(Stack, [], restart: :temporary)

  The `:temporary` option will tell the supervisor to not restart
  the worker when it exits. Read the "Exit reasons" section later on
  for more information.

  The second option is to give a name when starting the Stack agent:

      DynamicSupervisor.start_child(sup, [[:hello], [name: MyStack]])

  Now whenever that particular agent is started or restarted, it will
  be registered with a `MyStack` name which we can use when accessing
  it:

      Stack.pop(MyStack)
      #=> [:hello]

  And that's it. If the stack crashes, another stack will be up and
  register itself with name `MyStack`.

  ## Module-based supervisors

  In the example above, a supervisor was started by passing the
  supervision structure to `start_link/2`. However, supervisors
  can also be created by explicitly defining a supervision module:

      defmodule MyApp.Supervisor do
        use DynamicSupervisor

        def start_link do
          DynamicSupervisor.start_link(__MODULE__, [])
        end

        def init([]) do
          children = [
            worker(Stack, [[:hello]])
          ]

          {:ok, children, strategy: :one_for_one}
        end
      end

  You may want to use a module-based supervisor if you need to
  perform some particular action on supervisor initialization,
  like setting up an ETS table.

  ## Strategies

  Currently dynamic supervisors support a single strategy:

    * `:one_for_one` - if a child process terminates, only that
      process is restarted.

  ## Exit reasons

  From the example above, you may have noticed that the transient restart
  strategy for the worker does not restart the child in case it crashes with
  reason `:normal`, `:shutdown` or `{:shutdown, term}`.

  So one may ask: which exit reason should I choose when exiting my worker?
  There are three options:

    * `:normal` - in such cases, the exit won't be logged, there is no restart
      in transient mode and linked processes do not exit

    * `:shutdown` or `{:shutdown, term}` - in such cases, the exit won't be
      logged, there is no restart in transient mode and linked processes exit
      with the same reason unless trapping exits

    * any other term - in such cases, the exit will be logged, there are
      restarts in transient mode and linked processes exit with the same reason
      unless trapping exits

  ## Name Registration

  A supervisor is bound to the same name registration rules as a `GenServer`.
  Read more about it in the `GenServer` docs.
  """

  @behaviour GenServer

  @typedoc "Options used by the `start*` functions"
  @type options :: [registry: atom,
                    name: Supervisor.name,
                    strategy: Supervisor.Spec.strategy,
                    max_restarts: non_neg_integer,
                    max_seconds: non_neg_integer]

  @doc """
  Callback invoked to start the supervisor and during hot code upgrades.

  ## Options

    * `:strategy` - the restart strategy option. Only `:one_for_one`
      is supported by dynamic supervisors.

    * `:max_restarts` - the maximum amount of restarts allowed in
      a time frame. Defaults to 3.

    * `:max_seconds` - the time frame in which `:max_restarts` applies.
      Defaults to 5.

  """
  @callback init(args :: term) ::
    {:ok, [Supervisor.Spec.spec], options :: Keyword.t} | :ignore

  defstruct [:name, :mod, :args, :template, :max_restarts, :max_seconds, :strategy,
             children: %{}, restarts: [], restarting: 0]

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behaviour DynamicSupervisor
      import Supervisor.Spec
    end
  end

  # TODO: Add max_demand / min_demand (pull)
  # TODO: Add max_children (push)

  @doc """
  Starts a supervisor with the given children.

  A strategy is required to be given as an option. Furthermore,
  the `:max_restarts` and `:max_seconds` value can be configured
  as described in the documentation for the `c:init/1` callback.

  The options can also be used to register a supervisor name.
  The supported values are described under the `Name Registration`
  section in the `GenServer` module docs.

  Note that the dynamic supervisor is linked to the parent process
  and will exit not only on crashes but also if the parent process
  exits with `:normal` reason.
  """
  @spec start_link([Supervisor.Spec.spec], options) :: Supervisor.on_start
  def start_link(children, options) when is_list(children) do
    # TODO: Do not call supervise but the shared spec validation logic
    {:ok, {_, spec}} = Supervisor.Spec.supervise(children, options)
    start_link(Supervisor.Default, {:ok, spec, options}, options)
  end

  @doc """
  Starts a dynamic supervisor module with the given `arg`.

  To start the supervisor, the `init/1` callback will be invoked in the given
  module, with `arg` passed to it. The `init/1` callback must return a
  supervision specification which can be created with the help of the
  `Supervisor.Spec` module.

  If the `init/1` callback returns `:ignore`, this function returns
  `:ignore` as well and the supervisor terminates with reason `:normal`.
  If it fails or returns an incorrect value, this function returns
  `{:error, term}` where `term` is a term with information about the
  error, and the supervisor terminates with reason `term`.

  The `:name` option can also be given in order to register a supervisor
  name, the supported values are described under the `Name Registration`
  section in the `GenServer` module docs.
  """
  @spec start_link(module, any, [options]) :: Supervisor.on_start
  def start_link(mod, args, opts \\ []) do
    GenServer.start_link(__MODULE__, {mod, args, opts[:name]}, opts)
  end

  @doc """
  Starts a child in the dynamic supervisor.

  The child process will be started by appending the given list of
  `args` to the existing function arguments in the child specification.

  If the child process starts, function returns `{:ok, child}` or
  `{:ok, child, info}`, the pid is added to the supervisor and the
  function returns the same value.

  If the child process starts, function returns ignore, an error tuple
  or an erroneous value, or if it fails, the child is discarded and
  `:ignore` or `{:error, error}` where `error` is a term containing
  information about the error is returned.
  """
  @spec start_child(Supervisor.supervisor, [term]) :: Supervisor.on_start_child
  def start_child(supervisor, args) when is_list(args) do
    call(supervisor, {:start_child, args})
  end

  @doc """
  Terminates the given child pid.

  If successful, the function returns `:ok`. If there is no
  such pid, the function returns `{:error, :not_found}`.
  """
  @spec terminate_child(Supervisor.supervisor, pid) :: :ok | {:error, :not_found}
  def terminate_child(supervisor, pid) when is_pid(pid) do
    call(supervisor, {:terminate_child, pid})
  end

  @doc """
  Returns a list with information about all children.

  Note that calling this function when supervising a large number
  of children under low memory conditions can cause an out of memory
  exception.

  This function returns a list of tuples containing:

    * `id` - as defined in the child specification but is always
      set to `:undefined` for dynamic supervisors

    * `child` - the pid of the corresponding child process or the
      atom `:restarting` if the process is about to be restarted

    * `type` - `:worker` or `:supervisor` as defined in the child
      specification

    * `modules` - as defined in the child specification
  """
  @spec which_children(Supervisor.supervisor) ::
        [{:undefined, pid | :restarting, Supervisor.Spec.worker, Supervisor.Spec.modules}]
  def which_children(supervisor) do
    call(supervisor, :which_children)
  end

  @doc """
  Returns a map containing count values for the supervisor.

  The map contains the following keys:

    * `:specs` - always 1 as dynamic supervisors have a single specification

    * `:active` - the count of all actively running child processes managed by
      this supervisor

    * `:supervisors` - the count of all supervisors whether or not the child
      process is still alive

    * `:workers` - the count of all workers, whether or not the child process
      is still alive

  """
  @spec count_children(Supervisor.supervisor) ::
        %{specs: non_neg_integer, active: non_neg_integer,
          supervisors: non_neg_integer, workers: non_neg_integer}
  def count_children(supervisor) do
    call(supervisor, :count_children)
  end

  @compile {:inline, call: 2}

  defp call(supervisor, req) do
    GenServer.call(supervisor, req, :infinity)
  end

  ## Callbacks

  def init({mod, args, name}) do
    Process.put(:"$initial_call", {:supervisor, mod, 1})
    Process.flag(:trap_exit, true)

    case mod.init(args) do
      {:ok, children, opts} ->
        case validate_specs(children) do
          :ok ->
            case init(name, mod, args, children, opts) do
              {:ok, state} -> {:ok, state}
              {:error, message} -> {:stop, {:bad_opts, message}}
            end
          {:error, message} ->
            {:stop, {:bad_specs, message}}
        end
      :ignore ->
        :ignore
      other ->
        {:stop, {:bad_return_value, other}}
    end
  end

  defp init(name, mod, args, [child], opts) when is_list(opts) do
    strategy     = opts[:strategy]
    max_restarts = Keyword.get(opts, :max_restarts, 3)
    max_seconds  = Keyword.get(opts, :max_seconds, 5)

    with :ok <- validate_strategy(strategy),
         :ok <- validate_restarts(max_restarts),
         :ok <- validate_seconds(max_seconds) do
      {:ok, %DynamicSupervisor{mod: mod, args: args, template: child,
                               strategy: strategy, name: name || {self(), mod},
                               max_restarts: max_restarts, max_seconds: max_seconds}}
    end
  end
  defp init(_name, _mod, _args, [_], _opts) do
    {:error, "supervisor's init expects a keywords list as options"}
  end

  defp validate_specs([_]) do
    :ok # TODO: Do proper spec validation
  end
  defp validate_specs(_children) do
    {:error, "dynamic supervisor expects a list with a single item as a template"}
  end

  defp validate_strategy(strategy) when strategy in [:one_for_one], do: :ok
  defp validate_strategy(nil), do: {:error, "supervisor expects a strategy to be given"}
  defp validate_strategy(_), do: {:error, "unknown supervision strategy for dynamic supervisor"}

  defp validate_restarts(restart) when is_integer(restart), do: :ok
  defp validate_restarts(_), do: {:error, "max_restarts must be an integer"}

  defp validate_seconds(seconds) when is_integer(seconds), do: :ok
  defp validate_seconds(_), do: {:error, "max_seconds must be an integer"}

  @doc false
  def handle_call(:which_children, _from, state) do
    %{children: children, template: child} = state
    {_, _, _, _, type, mods} = child

    reply =
      for {pid, args} <- children do
        maybe_pid =
          case args do
            {:restarting, _} -> :restarting
            _ -> pid
          end
        {:undefined, maybe_pid, type, mods}
      end

    {:reply, reply, state}
  end

  def handle_call(:count_children, _from, state) do
    %{children: children, template: child, restarting: restarting} = state
    {_, _, _, _, type, _} = child

    specs  = map_size(children)
    active = specs - restarting
    reply  =
      case type do
        :supervisor ->
          %{specs: 1, active: active, workers: 0, supervisors: specs}
        :worker ->
          %{specs: 1, active: active, workers: specs, supervisors: 0}
      end

    {:reply, reply, state}
  end

  def handle_call({:terminate_child, pid}, _from, %{children: children} = state) do
    case children do
      %{^pid => args} ->
        :ok = terminate_children(%{pid => args}, state)
        {:reply, :ok, delete_child(pid, state)}
      %{} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:start_child, extra}, _from, state) do
    %{template: child} = state
    {_, {m, f, args}, restart, _, _, _} = child
    args = args ++ extra

    case reply = start_child(m, f, args) do
      {:ok, pid, _} ->
        {:reply, reply, save_child(restart, pid, args, state)}
      {:ok, pid} ->
        {:reply, reply, save_child(restart, pid, args, state)}
      _ ->
        {:reply, reply, state}
    end
  end

  defp start_child(m, f, a) do
    try do
      apply(m, f, a)
    catch
      kind, reason ->
        {:error, exit_reason(kind, reason, System.stacktrace)}
    else
      {:ok, pid, extra} when is_pid(pid) -> {:ok, pid, extra}
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      :ignore -> :ignore
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp save_child(:temporary, pid, _, state),
    do: put_in(state.children[pid], :undefined)
  defp save_child(_, pid, args, state),
    do: put_in(state.children[pid], args)

  defp exit_reason(:exit, reason, _),      do: reason
  defp exit_reason(:error, reason, stack), do: {reason, stack}
  defp exit_reason(:throw, value, stack),  do: {{:nocatch, value}, stack}

  @doc false
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, reason}, state) do
    case maybe_restart_child(pid, reason, state) do
      {:ok, state} ->
        {:noreply, state}
      {:shutdown, state} ->
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:"$gen_restart", pid}, state) do
    %{children: children, template: child, restarting: restarting} = state
    state = %{state | restarting: restarting - 1}

    case children do
      %{^pid => restarting_args} ->
        {:restarting, args} = restarting_args

        case restart_child(pid, args, child, state) do
          {:ok, state} ->
            {:noreply, state}
          {:shutdown, state} ->
            {:stop, :shutdown, state}
        end

      # We may hit clause if we send $gen_restart and then
      # someone calls terminate_child, removing the child.
      %{} ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    :error_logger.error_msg('Supervisor received unexpected message: ~p~n', [msg])
    {:noreply, state}
  end

  @doc false
  def terminate(_, %{children: children} = state) do
    :ok = terminate_children(children, state)
  end

  defp terminate_children(children, %{template: template} = state) do
    {_, _, restart, shutdown, _, _} = template

    {pids, stacks} = monitor_children(children, restart)
    size = map_size(pids)

    stacks =
      case shutdown do
        :brutal_kill ->
          for {pid, _} <- pids, do: Process.exit(pid, :kill)
          wait_children(restart, shutdown, pids, size, nil, stacks)
        :infinity ->
          for {pid, _} <- pids, do: Process.exit(pid, :shutdown)
          wait_children(restart, shutdown, pids, size, nil, stacks)
        time ->
          for {pid, _} <- pids, do: Process.exit(pid, :shutdown)
          timer = :erlang.start_timer(time, self(), :kill)
          wait_children(restart, shutdown, pids, size, timer, stacks)
      end

    for {pid, reason} <- stacks do
      report_error(:shutdown_error, reason, pid, :undefined, template, state)
    end

    :ok
  end

  defp monitor_children(children, restart) do
    Enum.reduce children, {%{}, %{}}, fn
      {_, {:restarting, _}}, {pids, stacks} ->
        {pids, stacks}
      {pid, _}, {pids, stacks} ->
        case monitor_child(pid) do
          :ok ->
            {Map.put(pids, pid, true), stacks}
          {:error, :normal} when restart != :permanent ->
            {pids, stacks}
          {:error, reason} ->
            {pids, Map.put(stacks, pid, reason)}
        end
    end
  end

  defp monitor_child(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, reason} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> {:error, reason}
        end
    after
      0 -> :ok
    end
  end

  defp wait_children(_restart, _shutdown, _pids, 0, nil, stacks) do
    stacks
  end
  defp wait_children(_restart, _shutdown, _pids, 0, timer, stacks) do
    _ = :erlang.cancel_timer(timer)
    receive do
      {:timeout, ^timer, :kill} -> :ok
    after
      0 -> :ok
    end
    stacks
  end
  defp wait_children(restart, :brutal_kill, pids, size, timer, stacks) do
    receive do
      {:DOWN, _ref, :process, pid, :killed} ->
        wait_children(restart, :brutal_kill, Map.delete(pids, pid), size - 1, timer,
                      stacks)
      {:DOWN, _ref, :process, pid, reason} ->
        wait_children(restart, :brutal_kill, Map.delete(pids, pid), size - 1, timer,
                      Map.put(stacks, pid, reason))
    end
  end
  defp wait_children(restart, shutdown, pids, size, timer, stacks) do
    receive do
      {:DOWN, _ref, :process, pid, :shutdown} ->
        wait_children(restart, shutdown, Map.delete(pids, pid), size - 1, timer,
                      stacks)
      {:DOWN, _ref, :process, pid, :normal} when restart != :permanent ->
        wait_children(restart, shutdown, Map.delete(pids, pid), size - 1, timer,
                      stacks)
      {:DOWN, _ref, :process, pid, reason} ->
        wait_children(restart, shutdown, Map.delete(pids, pid), size - 1, timer,
                      Map.put(stacks, pid, reason))
      {:timeout, ^timer, :kill} ->
        for {pid, _} <- pids, do: Process.exit(pid, :kill)
        wait_children(restart, shutdown, pids, size, nil, stacks)
    end
  end

  defp maybe_restart_child(pid, reason, state) do
    %{children: children, template: child} = state
    {_, _, restart, _, _, _} = child

    case children do
      %{^pid => args} -> maybe_restart_child(restart, reason, pid, args, child, state)
      %{} -> {:ok, state}
    end
  end

  defp maybe_restart_child(:permanent, reason, pid, args, child, state) do
    report_error(:child_terminated, reason, pid, args, child, state)
    restart_child(pid, args, child, state)
  end
  defp maybe_restart_child(_, :normal, pid, _args, _child, state) do
    {:ok, delete_child(pid, state)}
  end
  defp maybe_restart_child(_, :shutdown, pid, _args, _child, state) do
    {:ok, delete_child(pid, state)}
  end
  defp maybe_restart_child(_, {:shutdown, _}, pid, _args, _child, state) do
    {:ok, delete_child(pid, state)}
  end
  defp maybe_restart_child(:transient, reason, pid, args, child, state) do
    report_error(:child_terminated, reason, pid, args, child, state)
    restart_child(pid, args, child, state)
  end
  defp maybe_restart_child(:temporary, reason, pid, args, child, state) do
    report_error(:child_terminated, reason, pid, args, child, state)
    {:ok, delete_child(pid, state)}
  end

  defp delete_child(pid, %{children: children} = state) do
    %{state | children: Map.delete(children, pid)}
  end

  defp restart_child(pid, args, child, state) do
    case add_restart(state) do
      {:ok, %{strategy: strategy} = state} ->
        case restart_child(strategy, pid, args, child, state) do
          {:ok, state} ->
            {:ok, state}
          {:try_again, state} ->
            send(self(), {:"$gen_restart", pid})
            {:ok, state}
        end
      {:shutdown, state} ->
        report_error(:shutdown, :reached_max_restart_intensity, pid, args, child, state)
        {:shutdown, delete_child(pid, state)}
    end
  end

  defp add_restart(state) do
    %{max_seconds: max_seconds, max_restarts: max_restarts, restarts: restarts} = state
    now      = :erlang.monotonic_time(1)
    restarts = add_restart([now|restarts], now, max_seconds)
    state    = %{state | restarts: restarts}

    if length(restarts) <= max_restarts do
      {:ok, state}
    else
      {:shutdown, state}
    end
  end

  defp add_restart(restarts, now, period) do
    for then <- restarts, now <= then + period, do: then
  end

  defp restart_child(:one_for_one, current_pid, args, child, state) do
    {_, {m, f, _}, restart, _, _, _} = child

    case start_child(m, f, args) do
      {:ok, pid, _} ->
        {:ok, save_child(restart, pid, args, delete_child(current_pid, state))}
      {:ok, pid} ->
        {:ok, save_child(restart, pid, args, delete_child(current_pid, state))}
      :ignore ->
        {:ok, delete_child(current_pid, state)}
      {:error, reason} ->
        report_error(:start_error, reason, {:restarting, current_pid}, args, child, state)
        state = restart_child(current_pid, state)
        {:try_again, update_in(state.restarting, & &1 + 1)}
    end
  end

  defp restart_child(pid, %{children: children} = state) do
    case children do
      %{^pid => {:restarting, _}} ->
        state
      %{^pid => args} ->
        %{state | children: Map.put(children, pid, {:restarting, args})}
    end
  end

  defp report_error(error, reason, pid, args, child, %{name: name}) do
    :error_logger.error_report(:supervision_report,
      supervisor: name,
      errorContext: error,
      reason: reason,
      offender: extract_child(pid, args, child)
    )
  end

  defp extract_child(pid, args, {id, {m, f, _}, restart, shutdown, type, _}) do
    [pid: pid,
     id: id,
     mfargs: {m, f, args},
     restart_type: restart,
     shutdown: shutdown,
     child_type: type]
  end
end
