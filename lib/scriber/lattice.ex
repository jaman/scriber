defmodule Scriber.Lattice do
  @moduledoc """
  The on-disk half of the game: one directory of real files per stratum.

  A gate opens for one access code, and that code is written into the stratum's files rather
  than carried as an item. `Scriber.Console` is what reads them. Solving a stratum is: walk
  into the gate to learn its node state, `grep` the records at the console for that state,
  then `unseal` with the key on the line that matches.

  ## What a stratum looks like on disk

      <home>/runs/<seed>/stratum-2/
        README              what this stratum is, and which commands exist
        manifest            node records, one of which carries the gate's key
        logs/               from stratum 3 onwards, the manifest sharded one record per file
        gate.log            the gate controller's log
        .seal               the SHA-256 of the access code, never the code itself
        unsealed            created by `unseal/2` when a code is accepted

  Exactly one record carries `state=<gate_state/2>` and that record's `key=` is the access
  code from `code/2`. The other records are decoys wearing other states and other keys. From
  depth 3 onwards the records move into `logs/`, one per file, and `manifest` says so.

  Neither `.seal` nor `gate.log` contains the code or the gate's state, so reading every file
  in the directory is not enough to solve the stratum on its own.

  ## Where it lives

  `home/0` resolves the root directory: `$SCRIBER_HOME`, else `$XDG_STATE_HOME/scriber`, else
  `~/.local/state/scriber`. Nothing is ever deleted on the game's own initiative — runs
  accumulate one directory per seed until `destroy/1` removes one.

  ## Example

      dir = Scriber.Lattice.prepare(1234, 1)
      Scriber.Lattice.unsealed?(1234, 1)
      #=> false
  """

  @states ~w(quiesced paged faulted migrated pinned reaped cold warm stale)
  @decoys 11
  @shard_depth 3

  @doc """
  The directory every run is kept under.

  Resolved in order: `$SCRIBER_HOME`, then `$XDG_STATE_HOME/scriber`, then
  `~/.local/state/scriber`. An environment variable that is empty, unset, or holds a relative
  path counts as absent, as the XDG base directory specification requires. When the system
  reports no home directory, the temporary directory stands in for `~`.
  """
  @spec home() :: Path.t()
  def home do
    case env_dir("SCRIBER_HOME") do
      nil -> Path.join(state_home(), "scriber")
      dir -> dir
    end
  end

  defp state_home do
    env_dir("XDG_STATE_HOME") || Path.join(fallback_home(), ".local/state")
  end

  defp fallback_home, do: System.user_home() || System.tmp_dir!()

  defp env_dir(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      dir -> if Path.type(dir) == :absolute, do: dir, else: nil
    end
  end

  @doc "The directory holding a whole run, named for its seed."
  @spec root(integer()) :: Path.t()
  def root(seed), do: Path.join([home(), "runs", to_string(seed)])

  @doc "The directory for one stratum of a run."
  @spec stratum_dir(integer(), pos_integer()) :: Path.t()
  def stratum_dir(seed, depth), do: Path.join(root(seed), "stratum-#{depth}")

  @doc """
  The seeds of every run still on disk, most recently modified first.

  Directory names that are not whole integers are ignored, as is a missing `runs` directory,
  which yields `[]`.
  """
  @spec runs() :: [integer()]
  def runs do
    [home(), "runs"]
    |> Path.join()
    |> File.ls()
    |> case do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
    |> Enum.filter(&match?({_int, ""}, Integer.parse(&1)))
    |> Enum.sort_by(&modified_at/1, :desc)
    |> Enum.map(&elem(Integer.parse(&1), 0))
  end

  defp modified_at(name) do
    case File.stat(Path.join([home(), "runs", name]), time: :posix) do
      {:ok, stat} -> stat.mtime
      {:error, _reason} -> 0
    end
  end

  @doc """
  Write the stratum's files, creating the directory if needed, and return its path.

  Writes `.seal`, `README`, the records (`manifest`, or `logs/shard-N.log` from depth 3), and
  `gate.log`, overwriting any that exist. Idempotent: everything written is derived from
  `seed` and `depth`, so re-preparing a stratum reproduces it byte for byte.

  Files this function does not write are left alone, including the `unsealed` marker, so
  re-preparing an opened stratum does not seal it again.
  """
  @spec prepare(integer(), pos_integer()) :: Path.t()
  def prepare(seed, depth) do
    dir = stratum_dir(seed, depth)
    File.mkdir_p!(Path.join(dir, "logs"))

    code = code(seed, depth)
    state = gate_state(seed, depth)
    records = records(seed, depth, code, state)

    File.write!(Path.join(dir, ".seal"), hash(code) <> "\n")
    File.write!(Path.join(dir, "README"), readme(depth))
    write_records(dir, depth, records)
    write_logs(dir, depth, state)

    dir
  end

  @doc """
  The access code that opens a stratum's gate: eight lowercase hex characters.

  A pure function of `seed` and `depth`. The game never shows this to the player; it is
  written into exactly one record by `prepare/2` and has to be found there.
  """
  @spec code(integer(), pos_integer()) :: String.t()
  def code(seed, depth) do
    :sha256
    |> :crypto.hash("scriber:#{seed}:#{depth}")
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end

  @doc """
  The node state naming which record carries the gate's key.

  A pure function of `seed` and `depth`, drawn from a fixed vocabulary of state words. No
  decoy record ever wears this state, so exactly one record in the stratum matches it. The
  player learns it by walking into the gate, not from any file.
  """
  @spec gate_state(integer(), pos_integer()) :: String.t()
  def gate_state(seed, depth) do
    index = :erlang.phash2({seed, depth, :state}, length(@states))
    Enum.at(@states, index)
  end

  @doc "Whether this stratum's gate has been opened from the console."
  @spec unsealed?(integer(), pos_integer()) :: boolean()
  def unsealed?(seed, depth) do
    seed |> stratum_dir(depth) |> Path.join("unsealed") |> File.exists?()
  end

  @doc """
  Record on disk that this stratum's gate has been opened.

  Writes the marker `unsealed/2` looks for. The marker survives `prepare/2`, so a stratum
  stays open once opened. Always returns `:ok`, including when the write fails because the
  stratum directory does not exist.
  """
  @spec unseal(integer(), pos_integer()) :: :ok
  def unseal(seed, depth) do
    seed |> stratum_dir(depth) |> Path.join("unsealed") |> File.write("opened\n")
    :ok
  end

  @doc "Delete a run's whole directory, every stratum and marker in it. Raises on failure."
  @spec destroy(integer()) :: :ok
  def destroy(seed) do
    File.rm_rf!(root(seed))
    :ok
  end

  defp hash(code), do: :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)

  defp records(seed, depth, code, state) do
    real = %{name: node_name(seed, depth, 0), state: state, key: code}

    decoys =
      for index <- 1..@decoys//1 do
        %{
          name: node_name(seed, depth, index),
          state: decoy_state(seed, depth, index, state),
          key: decoy_key(seed, depth, index)
        }
      end

    shuffle([real | decoys], {seed, depth})
  end

  defp node_name(seed, depth, index) do
    suffix =
      :sha256
      |> :crypto.hash("node:#{seed}:#{depth}:#{index}")
      |> binary_part(0, 2)
      |> Base.encode16(case: :lower)

    "node-#{suffix}"
  end

  defp decoy_key(seed, depth, index) do
    :sha256
    |> :crypto.hash("key:#{seed}:#{depth}:#{index}")
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end

  defp decoy_state(seed, depth, index, gate_state) do
    others = @states -- [gate_state]
    Enum.at(others, :erlang.phash2({seed, depth, index}, length(others)))
  end

  defp shuffle(list, key) do
    list
    |> Enum.with_index()
    |> Enum.sort_by(fn {_item, index} -> :erlang.phash2({key, index}) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp record_line(%{name: name, state: state, key: key}) do
    "#{name}  state=#{state}  key=#{key}"
  end

  defp write_records(dir, depth, records) when depth < @shard_depth do
    body = Enum.map_join(records, "\n", &record_line/1)
    File.write!(Path.join(dir, "manifest"), manifest_header(depth) <> body <> "\n")
  end

  defp write_records(dir, depth, records) do
    File.write!(
      Path.join(dir, "manifest"),
      manifest_header(depth) <>
        "this manifest was sharded when the stratum faulted.\n" <>
        "the records are in logs/. they were not indexed.\n"
    )

    records
    |> Enum.with_index(1)
    |> Enum.each(fn {record, index} ->
      path = Path.join([dir, "logs", "shard-#{index}.log"])
      File.write!(path, shard_body(record, index))
    end)
  end

  defp shard_body(record, index) do
    """
    == shard #{index} ==
    checksum ok
    #{record_line(record)}
    """
  end

  defp manifest_header(depth) do
    """
    # lattice node manifest — stratum #{depth}
    # one of these nodes holds the gate. its state is the gate's state.
    #
    """
  end

  defp write_logs(dir, depth, _state) do
    File.write!(
      Path.join(dir, "gate.log"),
      """
      [stratum #{depth}] gate controller online
      [stratum #{depth}] seal engaged; key withheld from this log
      [stratum #{depth}] node state no longer mirrored here after the fault
      [stratum #{depth}] read the state at the controller; the records are indexed on it
      """
    )
  end

  defp readme(depth) do
    """
    LATTICE MAINTENANCE CONSOLE — stratum #{depth}

    Everything here is a real file.

    The gate below this stratum is sealed. It opens for one access code, and that
    code is written in the node records somewhere under this directory.

    The records are indexed on the gate node's state, and this console cannot read
    it — the controller stopped mirroring it here after the fault. Walk into the
    gate; it reports its state to whoever is standing in front of it.

      probe manifest    where the node records are on this stratum
      unseal <code>     try a code against the seal
      forge             what your shards will buy
      help              everything this console does

    Reading tools are here too — ls, cat, grep. With the state in hand:

      grep <the state the gate reported> manifest#{shard_hint(depth)}

    Press [Esc] to step back to the Lattice. Every file here stays, including the
    marker that says the gate is open, so coming back picks up where you left off.
    """
  end

  defp shard_hint(depth) when depth < @shard_depth, do: ""

  defp shard_hint(_depth),
    do: "\n      grep <state> logs/<file>  # this stratum sharded its manifest"
end
