defmodule TestNervesHub.Load.Report do
  @moduledoc """
  Turns a run's samples into the numbers a regression check needs, and
  into something a person can read.

  The figures that matter, per `nerves_hub_web` node:

    * `rss_kb` at baseline (cluster up, no devices), at the end of the
      hold (everything connected and settled), and after the devices
      have gone and the node has had a moment to release memory;
    * the same for `:erlang.memory(:total)`;
    * bytes of RSS per connected device over the hold: how much a device
      costs the node while it is connected;
    * bytes of RSS, and of `:erlang.memory(:total)`, that did not come back
      after disconnect, per device. The Erlang figure is the leak signal;
      RSS also carries what the C allocator holds on to.

  Per-device figures include the node's fixed costs spread over the
  fleet, so they only settle once a fleet is a few hundred devices.
  """

  @type summary :: map()

  @doc "Summarise samples and the run's metadata."
  @spec summarise([map()], map()) :: summary()
  def summarise(samples, meta) do
    baseline = last_of(samples, :baseline)
    hold_end = last_of(samples, :hold)
    settled = last_of(samples, :settled)
    devices = meta.devices

    servers =
      for {node, base} <- baseline.servers, into: %{} do
        held = hold_end.servers[node]
        after_ = settled.servers[node]

        {node,
         %{
           role: base.role,
           rss_kb: %{baseline: base.rss_kb, hold: held.rss_kb, settled: after_.rss_kb},
           erlang_total_kb: %{
             baseline: kb(base.memory["total"]),
             hold: kb(held.memory["total"]),
             settled: kb(after_.memory["total"])
           },
           erlang_hold_kb: %{
             processes: kb(held.memory["processes_used"]),
             binary: kb(held.memory["binary"]),
             ets: kb(held.memory["ets"]),
             system: kb(held.memory["system"])
           },
           channels_at_hold: held.channels,
           process_count_at_hold: held.process_count,
           rss_per_device_bytes: per_device(held.rss_kb - base.rss_kb, devices, held.channels),
           rss_retained_per_device_bytes:
             per_device(after_.rss_kb - base.rss_kb, devices, held.channels),
           # The leak signal. RSS can stay up after the devices leave because
           # the C allocator keeps freed pages; the BEAM's own accounting
           # going back to baseline says nothing is still referenced.
           erlang_retained_per_device_bytes:
             per_device(
               kb(after_.memory["total"]) - kb(base.memory["total"]),
               devices,
               held.channels
             ),
           erlang_per_device_bytes:
             per_device(
               kb(held.memory["total"]) - kb(base.memory["total"]),
               devices,
               held.channels
             )
         }}
      end

    hosts =
      for {node, held} <- hold_end.hosts, into: %{} do
        base = baseline.hosts[node]

        {node,
         %{
           rss_kb: %{baseline: base.rss_kb, hold: held.rss_kb},
           running: held.running,
           connected: held.connected,
           rss_per_device_bytes: per_device(held.rss_kb - base.rss_kb, held.running, held.running)
         }}
      end

    Map.merge(meta, %{
      servers: servers,
      hosts: hosts,
      online_at_hold: hold_end.online,
      sample_count: length(samples)
    })
  end

  @doc "A Markdown rendering of a summary."
  @spec to_markdown(summary()) :: String.t()
  def to_markdown(s) do
    label = if s[:label], do: " (#{s.label})", else: ""

    server_rows =
      for {node, r} <- s.servers do
        "| #{node} | #{r.role} | #{r.rss_kb.baseline} | #{r.rss_kb.hold} | #{r.rss_kb.settled} | " <>
          "#{r.erlang_total_kb.baseline} | #{r.erlang_total_kb.hold} | #{r.erlang_total_kb.settled} | " <>
          "#{r.channels_at_hold} | #{fmt_bytes(r.rss_per_device_bytes)} | #{fmt_bytes(r.erlang_per_device_bytes)} | " <>
          "#{fmt_bytes(r.rss_retained_per_device_bytes)} | #{fmt_bytes(r.erlang_retained_per_device_bytes)} |"
      end

    host_rows =
      for {node, h} <- s.hosts do
        "| #{node} | #{h.running} | #{h.connected} | #{h.rss_kb.baseline} | #{h.rss_kb.hold} | #{fmt_bytes(h.rss_per_device_bytes)} |"
      end

    """
    # Load run #{s.run_id}#{label}

    * web: `#{s.web_ref}` at `#{s.web_path}`
    * devices: #{s.devices} over #{map_size(s.hosts)} host(s), #{s.device_nodes} device node(s) in `#{s.device_node_env}`
    * ramp #{s.ramp_per_second}/s, hold #{s.hold_seconds}s, serializer #{s.serializer}, compress #{s.compress}
    * time to connect all: #{s.connect_seconds}s; NervesHub counted #{s.online_at_hold} online at hold end

    ## nerves_hub_web nodes

    | node | role | RSS base kB | RSS hold kB | RSS settled kB | erl base kB | erl hold kB | erl settled kB | channels | RSS/device | erl/device | RSS retained/device | erl retained/device |
    | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{Enum.join(server_rows, "\n")}

    ## device hosts

    | node | running | connected | RSS base kB | RSS hold kB | RSS/device |
    | --- | ---: | ---: | ---: | ---: | ---: |
    #{Enum.join(host_rows, "\n")}
    """
  end

  @doc "Side-by-side of two summaries (JSON files or maps), per server role."
  @spec compare(summary() | Path.t(), summary() | Path.t()) :: String.t()
  def compare(a, b) do
    a = load(a)
    b = load(b)

    rows =
      for role <- ["device", "all", "web"],
          {_, ra} <- Enum.filter(a.servers, fn {_, r} -> r.role == role end),
          {_, rb} <- Enum.filter(b.servers, fn {_, r} -> r.role == role end) do
        [
          "| #{role} RSS/device | #{fmt_bytes(ra.rss_per_device_bytes)} | #{fmt_bytes(rb.rss_per_device_bytes)} | #{pct(ra.rss_per_device_bytes, rb.rss_per_device_bytes)} |",
          "| #{role} erlang/device | #{fmt_bytes(ra.erlang_per_device_bytes)} | #{fmt_bytes(rb.erlang_per_device_bytes)} | #{pct(ra.erlang_per_device_bytes, rb.erlang_per_device_bytes)} |",
          "| #{role} RSS retained/device | #{fmt_bytes(ra.rss_retained_per_device_bytes)} | #{fmt_bytes(rb.rss_retained_per_device_bytes)} | #{pct(ra.rss_retained_per_device_bytes, rb.rss_retained_per_device_bytes)} |",
          "| #{role} erlang retained/device | #{fmt_bytes(ra[:erlang_retained_per_device_bytes])} | #{fmt_bytes(rb[:erlang_retained_per_device_bytes])} | #{pct(ra[:erlang_retained_per_device_bytes], rb[:erlang_retained_per_device_bytes])} |",
          "| #{role} RSS at hold kB | #{ra.rss_kb.hold} | #{rb.rss_kb.hold} | #{pct(ra.rss_kb.hold, rb.rss_kb.hold)} |"
        ]
      end

    """
    | metric | #{a[:label] || a.web_ref} | #{b[:label] || b.web_ref} | change |
    | --- | ---: | ---: | ---: |
    #{rows |> List.flatten() |> Enum.join("\n")}
    | connect all (s) | #{a.connect_seconds} | #{b.connect_seconds} | #{pct(a.connect_seconds, b.connect_seconds)} |
    """
  end

  defp load(path) when is_binary(path), do: path |> File.read!() |> Jason.decode!(keys: :atoms)
  defp load(map) when is_map(map), do: map

  defp last_of(samples, phase) do
    samples
    |> Enum.filter(&(to_string(&1[:phase] || &1["phase"]) == to_string(phase)))
    |> List.last()
    |> atomise()
    |> case do
      nil -> raise "no #{phase} sample in the run"
      sample -> sample
    end
  end

  # Samples read back from JSON have string keys at the top; node names
  # and memory keys stay strings either way.
  defp atomise(nil), do: nil

  defp atomise(sample) do
    %{
      phase: sample[:phase] || sample["phase"],
      online: sample[:online] || sample["online"],
      servers: node_map(sample[:servers] || sample["servers"]),
      hosts: node_map(sample[:hosts] || sample["hosts"])
    }
  end

  defp node_map(map) do
    for {node, values} <- map, into: %{} do
      {to_string(node), Map.new(values, fn {k, v} -> {to_atom(k), v} end)}
    end
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k), do: String.to_atom(k)

  defp kb(nil), do: 0
  defp kb(bytes), do: div(bytes, 1024)

  defp per_device(_kb, 0, _), do: nil
  defp per_device(kb, devices, _channels), do: div(kb * 1024, devices)

  defp fmt_bytes(nil), do: "-"
  defp fmt_bytes(b) when abs(b) >= 1_048_576, do: "#{Float.round(b / 1_048_576, 2)} MB"
  defp fmt_bytes(b) when abs(b) >= 1024, do: "#{Float.round(b / 1024, 1)} kB"
  defp fmt_bytes(b), do: "#{b} B"

  defp pct(nil, _), do: "-"
  defp pct(_, nil), do: "-"
  defp pct(0, _), do: "-"
  defp pct(a, b), do: "#{Float.round((b - a) / a * 100, 1)}%"
end
