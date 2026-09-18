# Scriber

A roguelike in the terminal, on [Cauldron](https://github.com/jaman/cauldron).

[![Scriber in play: a descent through the Lattice, with its sound](https://img.youtube.com/vi/AYlxc8u1FOw/maxresdefault.jpg)](https://www.youtube.com/watch?v=AYlxc8u1FOw)

A descent, with the sound, is [on YouTube](https://www.youtube.com/watch?v=AYlxc8u1FOw).

You are a maintenance construct inside the Lattice, a machine that is failing. Five strata
down is the way out. Each stratum's gate is sealed, and the code that opens it is not an item
and cannot be fought for — it is written in files, on a console, and you get it by running
real commands against them.

![Scriber: a husk process unravels beside the player, a cache mite in view, the log telling the fight](https://raw.githubusercontent.com/jaman/scriber/main/assets/scriber-combat.png)

```bash
mix scriber
mix scriber --seed 1234      # replay a particular run
mix scriber --mode text      # glyphs, even where the terminal has pixels
```

## The descent

You wake on the first stratum with fifty points of integrity, bare hands and a patch. The
rooms are dark until you walk into them. Somewhere on the stratum is a console; somewhere
else, the gate down, sealed. Between them, what is left of the machine's processes, and they
have noticed things are going wrong.

Nothing hostile starts within sight of where you wake. Everything else will notice you when
you can see it — with exceptions worth knowing.

## The console

Every stratum has a console. Standing on it and pressing `Enter` gives you a prompt, and the
gate's code is somewhere in what it can reach:

```
$ probe gate
gate node   : stratum-1 gate
state       : migrated
key         : withheld — held in the node records

$ grep migrated manifest
node-92aa  state=migrated  key=b6f69d5b

$ unseal b6f69d5b
code accepted.
the gate is open. step back to the Lattice and descend.
```

`help` lists what the console does: `ls`, `cat` and `grep` over the stratum's records,
`probe` for what the gate and the manifest will admit, `unseal` with the code, and `forge`
for what your shards will buy. The records are real files, and the console is a real
prompt; the answer is never simply in a file to `cat`. From the third stratum the records
are sharded into logs, and you will be grepping.

![Scriber's console: probe manifest and forge, with the stratum's records and what shards buy](https://raw.githubusercontent.com/jaman/scriber/main/assets/scriber-console.png)

`Esc` steps back to the Lattice. What you found stays found: the stratum's files, and an
open gate, stay open.

## Playing

| key | |
|---|---|
| `hjkl` `yubn` `qezc`, arrows | move; walk into something to attack it, or slip past it if it is stunned |
| `.` or `s` | wait — silently |
| `Enter` | use what you stand on: the console, or an open gate |
| `Esc` | step back from the console; put a tool away |
| `a` | apply a patch |
| `f` / `x` | throw a fuse / a decoy: the move keys aim, `Tab` picks the next creature in view, `Enter` throws |
| `p` | trigger a pulse |
| `>` | descend an open gate |
| `0`–`4` | take up bare hands, or a bought weapon |
| `m` | mute |
| `r` | begin another run, once this one is over |
| `Q` | quit |

## Creatures

Four kinds, four verbs:

| | | |
|---|---|---|
| **cache mite** | avoid | quick and brittle; runs when hurt and comes back |
| **husk process** | outrun | slow and heavy; moves every other turn, so it can be walked around or fought in a doorway |
| **page sentry** | choose | never moves; wakes only when you come within three tiles or strike it, and sits on what it guards |
| **orphaned daemon** | sneak | fast, and hunts by sound: your footsteps within twelve tiles wake it; waiting is silent. From stratum 3 one guards the gate's room |

A creature that has not seen you for five turns settles back to sleep, so retreat is a real
move. Strikes miss — yours on `d10 > 1 + its defence`, theirs on yours — and a creature
strikes or moves in a turn, never both. Some carry a **fragment** of the gate's code (two,
three, then four a stratum) and drop it where they die; `probe gate` at the console shows the
characters in hand, `b6??9d??`, which is that much less to `grep` for.

## Tools

Found lying about, or bought at the forge with the shards that creatures leave:

* **fuse** — thrown at a tile in view within six; stuns everything within a tile of it for
  two turns. A stunned creature is walked past
* **decoy** — thrown; a noise that draws what is awake for six turns, daemons included
* **pulse** — no aim: everything at arm's reach is thrown back a tile and stunned for a turn.
  The panic button

The forge also sells weapons — a two-hander, a shield, daggers, a mace that stuns — and
patches, and buys them back for half.

## Going down

Strata change as you go: doors from stratum 2, which block sight until opened; the gate's
daemon from 3; sight shortens from 4. Descending hardens you by five integrity. The fifth
gate is the way out.

## Sound

Everything you hear is placed where it happened and fades with distance from where you
stand: your own footsteps; a creature's step, chatter and cry from where it is, so a
daemon's double beat is heard from two rooms away before it is seen; each weapon's swing and
each creature's flesh on a hit; misses, parries, stuns, deaths; pickups, the patch, the door,
the console, the gate grinding open, the drop. Under it, each stratum has its own bed.

## Your runs

A run is kept on disk under `~/.local/state/scriber/runs/<seed>/` — the strata's files, and
what you did at their consoles — so `mix scriber --seed 1234` walks the same Lattice again.
The game never deletes them.

## Under the hood

[TECHNICAL.md](TECHNICAL.md): the libraries, the world, the console's directory, the map as
an image, the layout of the code and the tests.
