defmodule ETrace.CallSeqTool do
  @moduledoc """
  Reports duration type traces
  """
  alias __MODULE__
  alias ETrace.{EventCall, EventReturnFrom, Matcher, Probe}
  use ETrace.Tool

  defmodule Event do
    @moduledoc """
    Event generated by the CallSeqTool
    """
    defstruct type: nil,
              depth: 0,
              pid: nil,
              mod: nil,
              fun: nil,
              arity: nil,
              message: nil,
              return_value: nil

    defimpl String.Chars, for: Event do
      def to_string(%Event{type: :enter} = event) do
        String.duplicate(" ", event.depth) <>
          "-> #{inspect event.mod}.#{event.fun}/#{event.arity} " <>
          "#{message_to_string event.message}"
      end
      def to_string(%Event{type: :exit} = event) do
        String.duplicate(" ", event.depth) <>
          "<- #{inspect event.mod}.#{event.fun}/#{event.arity} " <>
          "#{inspect event.return_value}"
      end

      defp message_to_string(nil), do: ""
      defp message_to_string(term) when is_list(term) do
        term
        |> Enum.map(fn
          [key, val] -> {key, val}
          other -> "#{inspect other}"
        end)
        |> inspect()
      end
    end

  end

  defstruct ignore_recursion: nil,
            stacks: %{}

  def init(opts) do
    init_state = %CallSeqTool{}
    |> init_tool(opts)
    |> Map.put(:ignore_recursion,
               Keyword.get(opts, :ignore_recursion, false))

    case Keyword.get(opts, :match) do
      nil -> init_state
      %Matcher{} = matcher ->
        ms_with_return_trace = matcher.ms
        |> Enum.map(fn {head, condit, body} ->
          {head, condit, [{:return_trace} | body]}
        end)
        matcher = put_in(matcher.ms, ms_with_return_trace)
        probe = Probe.new(type: :call,
                          process: get_process(init_state),
                          match_by: matcher)
        set_probes(init_state, [probe])
    end
  end

  def handle_event(event, state) do
    case event do
      %EventCall{} -> handle_event_call(event, state)
      %EventReturnFrom{} -> handle_event_return_from(event, state)
      _ -> state
    end
  end

  def handle_event_call(%EventCall{pid: pid, mod: mod, fun: fun, arity: arity,
      ts: ts, message: m}, state) do
    enter_ts_ms = ts_to_ms(ts)
    key = inspect(pid)
    if state.ignore_recursion do
      state.stacks
      |> Map.get(key, [])
      |> case do
        [{:enter, {^mod, ^fun, ^arity, _c}, _ts} | _] ->
          state
        _ ->
          push_to_stack(key,
                        {:enter, {mod, fun, arity, m}, enter_ts_ms},
                        state)
      end
    else
      push_to_stack(key,
                    {:enter, {mod, fun, arity, m}, enter_ts_ms},
                    state)
    end
  end

  def handle_event_return_from(%EventReturnFrom{pid: pid, mod: mod, fun: fun,
      arity: arity, ts: ts, return_value: return_value}, state) do
    exit_ts_ms = ts_to_ms(ts)
    key = inspect(pid)
    if state.ignore_recursion do
      state.stacks
      |> Map.get(key, [])
      |> case do
        [{:exit, {^mod, ^fun, ^arity, _r}, _ts} | _] ->
          state
        _ ->
          push_to_stack(key,
                      {:exit, {mod, fun, arity, return_value}, exit_ts_ms},
                      state)
      end
    else
      push_to_stack(key,
                  {:exit, {mod, fun, arity, return_value}, exit_ts_ms},
                  state)
    end
  end

  def push_to_stack(key, stack, state) do
    new_stack = [stack |
                 Map.get(state.stacks, key, [])]
    put_in(state.stacks, Map.put(state.stacks, key, new_stack))
  end

  def handle_stop(state) do
    # get stack for each process
    state.stacks |> Enum.each(fn {pid, stack} ->
      # state.report_fun.("pid = #{pid}")
      stack
      |> Enum.reverse()
      |> Enum.reduce(0, fn
        {:enter, {mod, fun, arity, m}, _enter_ts_ms}, depth ->
          # state.report_fun.(%Event{
          report_event(state, %Event{
            type: :enter,
            depth: depth,
            pid: pid,
            mod: mod,
            fun: fun,
            arity: arity,
            message: m
          })
          depth + 1
        {:exit, {mod, fun, arity, return_value}, _exit_ts_ms}, depth ->
          # state.report_fun.(%Event{
          report_event(state, %Event{
            type: :exit,
            depth: depth - 1,
            pid: pid,
            mod: mod,
            fun: fun,
            arity: arity,
            return_value: return_value
          })
          depth - 1
      end)
    end)
    state
  end

  defp ts_to_ms({mega, seconds, us}) do
    (mega * 1_000_000 + seconds) * 1_000_000 + us # round(us/1000)
  end

end