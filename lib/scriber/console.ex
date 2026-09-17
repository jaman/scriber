defmodule Scriber.Console do
  @moduledoc """
  The maintenance console: a shell-like prompt over one stratum's directory, in Elixir.

  No shell is spawned and no pseudoterminal is opened. Every command is implemented here,
  against the files `Scriber.Lattice.prepare/2` wrote.

  ## Commands

      ls [path]              list a directory, marking subdirectories with /
      cat <file>...          print files
      grep <text> <file>...  print lines containing text
      probe <target>         manifest, seal, or all
      unseal <code>          test a code against the seal
      forge [thing]          list what shards buy, or buy one
      forge sell <weapon>    sell a weapon back for half
      clear                  empty the transcript
      help                   list these commands

  Paths are resolved relative to the console's `:cwd` and are not sandboxed to it. `probe
  gate` is accepted but does not report the gate's state; that is read by walking into the
  gate in the game.

  ## State

  The console owns `:input` (the prompt buffer) and `:lines` (the transcript, newest first,
  capped). `submit/3` is the whole interface — a line in, an updated console and game out.
  `unseal` writes a marker file through `Scriber.Lattice.unseal/2`; `forge` changes the game
  and touches no file, and records the transaction as an action in `:pending`, which
  `take_pending/1` hands over for the world that holds the game to apply.

  ## Example

      console = Scriber.Console.new(Scriber.Lattice.stratum_dir(seed, 1), 1)
      {console, game} = Scriber.Console.submit(%{console | input: "probe seal"}, game, seed: seed)
  """

  alias Scriber.{Forge, Gear, Lattice}

  @type t :: %__MODULE__{
          cwd: Path.t(),
          stratum: pos_integer(),
          input: String.t(),
          lines: [{String.t(), atom()}],
          pending: [atom()]
        }

  defstruct cwd: ".", stratum: 1, input: "", lines: [], pending: []

  @scrollback 500

  @doc """
  A console rooted at `cwd`, labelled for stratum `stratum`, with its banner already in the
  transcript.

  `cwd` should be the directory `Scriber.Lattice.prepare/2` returned. `stratum` is the depth
  the console belongs to and is the depth `unseal` acts on, so it must match `cwd`.
  """
  @spec new(Path.t(), pos_integer()) :: t()
  def new(cwd, stratum) do
    banner(%__MODULE__{cwd: cwd, stratum: stratum})
  end

  defp banner(console) do
    console
    |> say("LATTICE MAINTENANCE CONSOLE — stratum #{console.stratum}", :system)
    |> say("", :plain)
    |> say("The records are here. The gate's state is not — read that at the gate.", :plain)
    |> say("", :plain)
    |> say("  grep <state> manifest      the record carrying the key", :plain)
    |> say("  probe manifest    where the records are on this stratum", :plain)
    |> say("  forge             what shards will buy you", :plain)
    |> say("  help              everything this console does", :plain)
    |> say("", :plain)
    |> say("[Esc] steps back to the Lattice.", :dim)
    |> say("", :plain)
  end

  @doc "Append `char` to the prompt buffer. Appends whatever it is given, unvalidated."
  @spec type(t(), String.t()) :: t()
  def type(%__MODULE__{} = console, char), do: %{console | input: console.input <> char}

  @doc "Remove the last character from the prompt buffer. A no-op on an empty prompt."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{input: ""} = console), do: console

  def backspace(%__MODULE__{} = console) do
    %{console | input: String.slice(console.input, 0..-2//1)}
  end

  @doc """
  Run whatever is in the prompt buffer, returning `{console, game}`.

  The line is trimmed, echoed to the transcript, and split on whitespace. An empty line is
  echoed and nothing else runs. An unrecognised command prints an error rather than raising,
  as does any command whose files cannot be read.

  The returned console always has an empty `:input`. `game` is returned changed only by
  `forge`; every other command returns it untouched.

  ## Options

    * `:seed` — the run's seed. Required by `unseal`, which raises `KeyError` without it.
      Other commands ignore it.
  """
  @spec submit(t(), Scriber.Game.t(), keyword()) :: {t(), Scriber.Game.t()}
  def submit(%__MODULE__{} = console, game, opts \\ []) do
    line = String.trim(console.input)
    console = %{console | input: ""} |> say("$ #{line}", :prompt)

    case String.split(line, ~r/\s+/, trim: true) do
      [] -> {console, game}
      [command | args] -> run(console, game, command, args, opts)
    end
  end

  defp pend(console, action), do: %{console | pending: console.pending ++ [action]}

  @doc "The forge actions run since the last call, oldest first, and the console with none pending; a world takes them as input."
  @spec take_pending(t()) :: {[atom()], t()}
  def take_pending(%__MODULE__{pending: pending} = console),
    do: {pending, %{console | pending: []}}

  @doc """
  Everything printed so far as `{text, tone}` pairs, oldest first.

  Tones are `:system`, `:prompt`, `:good`, `:bad`, `:dim` and `:plain`, for the caller to
  colour. The transcript is capped, so the oldest lines of a long session are absent.
  """
  @spec transcript(t()) :: [{String.t(), atom()}]
  def transcript(%__MODULE__{lines: lines}), do: Enum.reverse(lines)

  defp run(console, game, "probe", ["gate"], _opts) do
    {console
     |> say("  the gate node does not answer from here.", :plain)
     |> say(
       "  walk into the gate itself; it reports its state to whoever is standing there.",
       :dim
     ), game}
  end

  defp run(console, game, "help", _args, _opts) do
    {console
     |> say("  ls [path]              what is here", :plain)
     |> say("  cat <file>             read a file", :plain)
     |> say("  grep <text> <file>     lines that contain something", :plain)
     |> say("  probe <target>         manifest, seal, all", :plain)
     |> say("  unseal <code>          try a code against the seal", :plain)
     |> say("  forge [thing]          list what shards buy, or buy it", :plain)
     |> say("  forge sell <weapon>    sell one back, for half", :plain)
     |> say("  clear                  wipe the transcript", :plain)
     |> say("  exit                   back to the Lattice", :plain), game}
  end

  defp run(console, game, "clear", _args, _opts), do: {%{console | lines: []}, game}

  defp run(console, game, "ls", args, _opts) do
    path = Path.join(console.cwd, List.first(args) || ".")

    case File.ls(path) do
      {:ok, names} ->
        {Enum.reduce(Enum.sort(names), console, &say(&2, "  #{&1}#{mark(path, &1)}", :plain)),
         game}

      {:error, reason} ->
        {error(console, "ls: #{:file.format_error(reason)}"), game}
    end
  end

  defp run(console, game, "cat", [], _opts), do: {error(console, "usage: cat <file>"), game}

  defp run(console, game, "cat", files, _opts) do
    {Enum.reduce(files, console, fn name, acc ->
       case read(console, name) do
         {:ok, text} -> Enum.reduce(String.split(text, "\n"), acc, &say(&2, &1, :plain))
         {:error, why} -> error(acc, "cat: #{name}: #{why}")
       end
     end), game}
  end

  defp run(console, game, "grep", [pattern | files], _opts) when files != [] do
    hits =
      Enum.flat_map(files, fn name ->
        case read(console, name) do
          {:ok, text} ->
            text
            |> String.split("\n")
            |> Enum.filter(&String.contains?(&1, pattern))
            |> Enum.map(&{name, &1})

          {:error, _why} ->
            []
        end
      end)

    case hits do
      [] ->
        {say(console, "  no match", :dim), game}

      found ->
        {Enum.reduce(found, console, fn {name, line}, acc ->
           label = if length(files) > 1, do: "#{name}: ", else: ""
           say(acc, "  #{label}#{line}", :plain)
         end), game}
    end
  end

  defp run(console, game, "grep", _args, _opts) do
    {error(console, "usage: grep <text> <file>..."), game}
  end

  defp run(console, game, "probe", ["manifest"], _opts), do: {probe_manifest(console), game}
  defp run(console, game, "probe", ["seal"], _opts), do: {probe_seal(console), game}

  defp run(console, game, "probe", ["all"], _opts) do
    {console |> probe_manifest() |> probe_seal(), game}
  end

  defp run(console, game, "probe", _args, _opts) do
    {error(console, "usage: probe <manifest|seal|all>   (the gate answers at the gate)"), game}
  end

  defp run(console, game, "unseal", [code], opts) do
    {try_code(console, code, opts), game}
  end

  defp run(console, game, "unseal", _args, _opts) do
    {error(console, "usage: unseal <code>"), game}
  end

  defp run(console, game, "forge", [], _opts), do: {listing(console, game), game}

  defp run(console, game, "forge", ["sell", what], _opts) do
    case Forge.sell(game, what) do
      {:ok, sold, message} ->
        {console |> say("  #{message}", :good) |> pend(Forge.action(:sell, what)), sold}

      {:error, why} ->
        {error(console, "forge: #{why}"), game}
    end
  end

  defp run(console, game, "forge", ["sell" | _args], _opts) do
    {error(console, "usage: forge sell <weapon>"), game}
  end

  defp run(console, game, "forge", [what], _opts) do
    case Forge.buy(game, what) do
      {:ok, bought, message} ->
        {console |> say("  #{message}", :good) |> pend(Forge.action(:buy, what)), bought}

      {:error, why} ->
        {error(console, "forge: #{why}"), game}
    end
  end

  defp run(console, game, "forge", _args, _opts) do
    {error(console, "usage: forge [thing | sell <weapon>]"), game}
  end

  defp run(console, game, other, _args, _opts) do
    {error(console, "#{other}: not a command here. try `help`."), game}
  end

  defp try_code(console, code, opts) do
    seed = Keyword.fetch!(opts, :seed)

    if Lattice.code(seed, console.stratum) == String.trim(code) do
      Lattice.unseal(seed, console.stratum)

      console
      |> say("  seal accepted. the gate is open.", :good)
      |> say("  [Esc] back, and walk to it.", :dim)
    else
      error(console, "unseal: the seal rejects that code")
    end
  end

  defp probe_manifest(console) do
    case read(console, "manifest") do
      {:ok, text} ->
        count = text |> String.split("\n") |> Enum.count(&String.contains?(&1, "key="))

        console
        |> say("  records     : ./manifest", :plain)
        |> say("  count       : #{count}", :plain)

      {:error, _why} ->
        shards = shard_count(Path.join(console.cwd, "logs"))

        console
        |> say("  records     : sharded into ./logs/", :plain)
        |> say("  count       : #{shards} shards", :plain)
        |> say("  hint        : grep <state> logs/*", :plain)
    end
  end

  defp probe_seal(console) do
    open? = File.exists?(Path.join(console.cwd, "unsealed"))
    say(console, "  seal        : #{if open?, do: "open", else: "engaged"}", :plain)
  end

  defp shard_count(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.count(names, &keyed?(Path.join(dir, &1)))
      {:error, _reason} -> 0
    end
  end

  defp keyed?(path) do
    case File.read(path) do
      {:ok, text} -> String.contains?(text, "key=")
      _unreadable -> false
    end
  end

  defp listing(console, game) do
    console =
      Enum.reduce(Forge.listing(game), console, fn item, acc ->
        say(acc, "  #{pad(item.key, 14)}#{pad(to_string(item.cost), 5)}#{item.blurb}", :plain)
      end)

    console
    |> say("", :plain)
    |> say(
      "  #{game.shards} shards. `forge <thing>` to buy, `forge sell <weapon>` for half.",
      :dim
    )
  end

  defp read(console, name) do
    path = Path.join(console.cwd, name)

    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  defp mark(dir, name) do
    if File.dir?(Path.join(dir, name)), do: "/", else: ""
  end

  defp pad(text, width), do: String.pad_trailing(text, width)

  defp error(console, text), do: say(console, "  #{text}", :bad)

  defp say(console, text, tone) do
    %{console | lines: Enum.take([{text, tone} | console.lines], @scrollback)}
  end

  @doc false
  def gear_names, do: Enum.map(Gear.purchasable(), &to_string/1)
end
