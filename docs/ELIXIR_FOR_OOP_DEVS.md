# Elixir for Java/C# Developers

A guide to reading and contributing to this codebase if you're coming from an object-oriented background. Every concept is illustrated with real examples from Cerno.

---

## Table of Contents

1. [Modules Are Not Classes](#1-modules-are-not-classes)
2. [Data Is Immutable — Always](#2-data-is-immutable--always)
3. [Pattern Matching Replaces if/switch/overloads](#3-pattern-matching-replaces-ifswitchoverloads)
4. [The Pipeline Operator (`|>`)](#4-the-pipeline-operator-)
5. [Tagged Tuples Instead of Exceptions](#5-tagged-tuples-instead-of-exceptions)
6. [`with` Chains — Controlled Early Return](#6-with-chains--controlled-early-return)
7. [Structs — Not Objects](#7-structs--not-objects)
8. [Behaviours — Elixir's Interfaces](#8-behaviours--elixirs-interfaces)
9. [Ecto — The ORM That Isn't](#9-ecto--the-orm-that-isnt)
10. [GenServer — Stateful Processes](#10-genserver--stateful-processes)
11. [Supervision Trees — Let It Crash](#11-supervision-trees--let-it-crash)
12. [PubSub — Decoupled Communication](#12-pubsub--decoupled-communication)
13. [Enum, Captures, and Closures](#13-enum-captures-and-closures)
14. [Module Attributes — Constants and Metadata](#14-module-attributes--constants-and-metadata)
15. [Keyword Lists — Ordered Options Bags](#15-keyword-lists--ordered-options-bags)
16. [Concurrency With Task](#16-concurrency-with-task)

---

## 1. Modules Are Not Classes

In Java/C# you define a class that bundles data and behavior. In Elixir, a **module** is just a namespace for functions. There are no instances, no `this`/`self`, no inheritance.

```csharp
// C#
public class Parser {
    private string path;
    public Parser(string path) { this.path = path; }
    public List<Fragment> Parse() { ... }
}
var p = new Parser("CLAUDE.md");
p.Parse();
```

```elixir
# Elixir — lib/cerno/atomic/parser.ex
defmodule Cerno.Atomic.Parser do
  def parse(path) do
    filename = Path.basename(path)
    case find_parser(filename) do
      {:ok, parser} -> parser.parse(path)
      :error -> {:error, :unknown_format}
    end
  end
end

# Called as:
Parser.parse("CLAUDE.md")
```

There's no object. `parse/1` takes the data it needs as an argument. The `/1` notation means "function named `parse` that takes 1 argument" — Elixir identifies functions by name **and** arity.

---

## 2. Data Is Immutable — Always

In Java/C# you mutate fields on an object. In Elixir, data never changes. You create **new** copies with modifications.

```csharp
// C#
state.Processing.Add(path);   // mutates the set in place
```

```elixir
# Elixir — lib/cerno/process/accumulator.ex:56
state = %{state | processing: MapSet.put(state.processing, path)}
```

`%{state | processing: ...}` creates a **new** map with the `processing` key replaced. The old `state` is untouched. This is why you see a lot of `variable = expression` rebinding — it's not mutation, it's creating new values and rebinding the name.

**Map update syntax:**
- `%{map | key: value}` — update existing keys (raises if key doesn't exist)
- `Map.put(map, key, value)` — insert or update

---

## 3. Pattern Matching Replaces if/switch/overloads

This is the single biggest mental shift. Pattern matching is used **everywhere**: function heads, `case`, `with`, and plain `=`.

### Multiple function clauses (like method overloading, but on values)

```csharp
// C#
public Classification Classify(object input) {
    if (input is Fragment f) return ClassifyText(f.Content, f.SectionHeading);
    if (input is string s) return ClassifyText(s, null);
    throw new ArgumentException();
}
```

```elixir
# Elixir — lib/cerno/short_term/classifier.ex:22-28
def classify(%{content: content, section_heading: heading}) do
  classify_text(content, heading)
end

def classify(content) when is_binary(content) do
  classify_text(content, nil)
end
```

Elixir tries each clause **top to bottom**. The first clause destructures a map that has both `:content` and `:section_heading` keys — pulling the values into local variables in one step. The second clause matches any binary string. The `when is_binary(content)` part is called a **guard**.

### Destructuring in `case`

```elixir
# lib/cerno/process/accumulator.ex:110-133
case check_file_changed(path) do
  :unchanged ->
    Logger.info("File unchanged, skipping #{path}")

  {:changed, file_hash} ->
    case Parser.parse(path) do
      {:ok, fragments} ->
        # use fragments...

      {:error, reason} ->
        Logger.error("Failed to parse #{path}: #{inspect(reason)}")
    end
end
```

Each `->` arm is a pattern. `{:changed, file_hash}` simultaneously checks that the value is a 2-tuple whose first element is the atom `:changed`, **and** binds the second element to `file_hash`.

### Destructuring in `=`

```elixir
# lib/cerno/process/accumulator.ex:344
{line_start, line_end} = fragment.line_range || {0, 0}
```

This is like `var (lineStart, lineEnd) = ...;` in C# tuple deconstruction, but it works on any data shape.

---

## 4. The Pipeline Operator (`|>`)

The pipe takes the result of the left side and passes it as the **first argument** to the right side. It replaces deeply nested calls or temporary variables.

```csharp
// C# — nested calls
var results = Take(SortBy(Filter(scored, s => s.Score >= minScore), s => s.Score), maxPrinciples);

// C# — LINQ
var results = scored.Where(s => s.Score >= minScore)
                    .OrderByDescending(s => s.Score)
                    .Take(maxPrinciples);
```

```elixir
# Elixir — lib/cerno/long_term/retriever.ex:42-45
results =
  scored
  |> Enum.filter(fn {_p, score} -> score >= min_score end)
  |> Enum.sort_by(fn {_p, score} -> score end, :desc)
  |> Enum.take(max_principles)
```

Read it top to bottom: start with `scored`, filter it, sort it, take N. The `_p` prefix means "I need to acknowledge this variable in the pattern but I'm not using it."

A longer pipeline from the domain detection logic:

```elixir
# lib/cerno/long_term/retriever.ex:63-74
content
|> String.split(~r/(\r?\n){2,}/)            # split on blank lines
|> Enum.reject(&(String.trim(&1) == ""))     # drop empty chunks
|> Enum.map(fn paragraph ->                   # classify each paragraph
  Classifier.classify(paragraph).domain
end)
|> Enum.reject(&is_nil/1)                    # drop nils
|> Enum.frequencies()                        # %{"elixir" => 5, "testing" => 2}
|> Enum.sort_by(fn {_d, count} -> count end, :desc)
|> Enum.take(3)                              # top 3 domains
|> Enum.map(fn {domain, _count} -> domain end)
```

---

## 5. Tagged Tuples Instead of Exceptions

Java/C# use exceptions for error handling. Elixir uses **tagged tuples** — the return value tells you whether it worked.

```csharp
// C#
try {
    var fragments = parser.Parse(path);
} catch (IOException ex) {
    logger.Error($"Failed: {ex.Message}");
}
```

```elixir
# Elixir — lib/cerno/atomic/parser.ex:35-41
case find_parser(filename) do
  {:ok, parser} -> parser.parse(path)
  :error -> {:error, :unknown_format}
end
```

The convention is universal:
- `{:ok, value}` — success
- `{:error, reason}` — failure
- Bare atoms like `:ok` or `:unchanged` for simple signals

Functions document this in their **typespecs**:

```elixir
# lib/cerno/embedding.ex:13
@callback embed(text :: String.t()) :: {:ok, embedding()} | {:error, term()}
```

This is the equivalent of `Result<Embedding, Error>` in Rust, or a hypothetical `Either` in C#. The caller **must** handle both cases — there's no unchecked exception sneaking through.

---

## 6. `with` Chains — Controlled Early Return

When you have sequential operations that each might fail, Java/C# developers reach for nested try-catch or early returns. Elixir uses `with`:

```csharp
// C#
var decoded = DecodeJson(json);
if (decoded == null) return Error("decode failed");
var result = ExtractResult(decoded);
if (result == null) return Error("extract failed");
// use result...
```

```elixir
# Elixir
with {:ok, decoded} <- decode_json(json_string),
     {:ok, result} <- extract_result(decoded) do
  # Both succeeded — use result
  {:ok, normalize_learnings(result)}
end
```

Each `<-` line is a pattern match. If a line doesn't match (e.g., `{:error, reason}` comes back), the `with` short-circuits and returns that non-matching value. No nesting, no explicit error handling at each step.

---

## 7. Structs — Not Objects

Structs are maps with a fixed set of keys and a name. They have no methods, no constructors, no inheritance.

```csharp
// C#
public class Fragment {
    public required string Id { get; init; }
    public required string Content { get; init; }
    public string? SectionHeading { get; init; }
    // ...
}
```

```elixir
# Elixir — lib/cerno/atomic/fragment.ex
defmodule Cerno.Atomic.Fragment do
  @enforce_keys [:id, :content, :source_path, :source_project, :file_hash, :extracted_at]
  defstruct [
    :id, :content, :source_path, :source_project,
    :section_heading, :line_range, :file_hash, :extracted_at
  ]

  def build_id(source_path, content) do
    :crypto.hash(:sha256, source_path <> content)
    |> Base.encode16(case: :lower)
  end
end
```

- `@enforce_keys` — compile error if you create a struct without these (like `required` in C#)
- `defstruct` — defines the shape
- `build_id/2` — just a function in the same module; it doesn't belong to a Fragment "instance"

Creating a struct:

```elixir
%Fragment{
  id: Fragment.build_id(path, content),
  content: content,
  source_path: path,
  # ...
}
```

Accessing fields: `fragment.content` (dot syntax, like C#).

**Type specs** describe the shape:

```elixir
@type t :: %__MODULE__{
  id: String.t(),
  content: String.t(),
  section_heading: String.t() | nil,
  line_range: {non_neg_integer(), non_neg_integer()},
  # ...
}
```

`__MODULE__` is a compile-time constant for the current module name (like `typeof(this).Name`).

---

## 8. Behaviours — Elixir's Interfaces

Behaviours are Elixir's answer to `interface` in Java/C#. They define a contract that implementing modules must fulfill.

**Defining the interface:**

```csharp
// C#
public interface IEmbeddingProvider {
    Task<float[]> Embed(string text);
    Task<float[][]> EmbedBatch(string[] texts);
    int Dimension { get; }
}
```

```elixir
# Elixir — lib/cerno/embedding.ex
defmodule Cerno.Embedding do
  @callback embed(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback embed_batch(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  @callback dimension() :: pos_integer()
end
```

**Implementing the interface:**

```csharp
// C#
public class OpenAIProvider : IEmbeddingProvider { ... }
```

```elixir
# Elixir — lib/cerno/embedding/openai.ex
defmodule Cerno.Embedding.OpenAI do
  @behaviour Cerno.Embedding

  @impl true
  def embed(text) do
    case embed_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def embed_batch(texts) when is_list(texts) do
    # ... HTTP call to OpenAI
  end

  @impl true
  def dimension, do: 1536
end
```

`@impl true` is a compiler annotation — it confirms "this function implements a behaviour callback" and warns at compile time if the signature doesn't match.

**Dynamic dispatch** (runtime polymorphism without inheritance):

```elixir
# lib/cerno/embedding.ex:23-24
def provider do
  Application.get_env(:cerno, :embedding)[:provider] || Cerno.Embedding.OpenAI
end

def embed(text), do: provider().embed(text)
```

The provider module is loaded from configuration. `provider().embed(text)` calls `embed/1` on whatever module is configured — OpenAI in production, Mock in tests. This is like dependency injection through configuration rather than constructor injection.

---

## 9. Ecto — The ORM That Isn't

Ecto looks like Entity Framework or Hibernate, but it's fundamentally different: there's no lazy loading, no change tracking, no implicit SQL. Everything is explicit.

### Schema = Entity

```csharp
// C# Entity Framework
[Table("insights")]
public class Insight {
    public int Id { get; set; }
    public string Content { get; set; }
    public float Confidence { get; set; } = 0.5f;
    public InsightStatus Status { get; set; } = InsightStatus.Active;
    public ICollection<InsightSource> Sources { get; set; }
}
```

```elixir
# Elixir — lib/cerno/short_term/insight.ex
schema "insights" do
  field :content, :string
  field :confidence, :float, default: 0.5
  field :status, Ecto.Enum, values: ~w(active contradicted superseded pending_review)a

  has_many :sources, Cerno.ShortTerm.InsightSource
  timestamps(type: :utc_datetime)
end
```

`~w(active contradicted)a` is a **sigil** — shorthand for `[:active, :contradicted]` (a list of atoms). The `a` modifier converts the words to atoms.

### Changeset = Validated Mutation Proposal

There's no `insight.Content = "new"` followed by `db.SaveChanges()`. Instead, you build a **changeset** — a data structure describing *proposed* changes with validation:

```elixir
# lib/cerno/short_term/insight.ex:41-61
def changeset(insight, attrs) do
  insight
  |> cast(attrs, [:content, :content_hash, :category, :confidence, ...])
  |> validate_required([:content, :content_hash])
  |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  |> unique_constraint(:content_hash)
end
```

Then you explicitly insert or update:

```elixir
# lib/cerno/process/accumulator.ex:316
case %Insight{} |> Insight.changeset(attrs) |> Repo.insert() do
  {:ok, insight} -> # success
  {:error, changeset} -> # validation failed, changeset.errors has details
end
```

### Queries are data, not strings

```elixir
# lib/cerno/short_term/insight.ex:91-98
from(i in __MODULE__,
  where: not is_nil(i.embedding),
  where: i.status == ^status,
  select: {i, fragment("1 - (? <=> ?)", i.embedding, ^embedding_literal)},
  order_by: fragment("? <=> ?", i.embedding, ^embedding_literal),
  limit: ^limit
)
```

- `from(i in __MODULE__, ...)` — like `from i in dbContext.Insights select ...` in LINQ
- `^variable` — the **pin operator** — interpolates a value into the query (parameterized, SQL-injection safe)
- `fragment(...)` — raw SQL escape hatch for things Ecto doesn't model (here: pgvector's `<=>` operator)

Queries are composable:

```elixir
query = from(i in Insight, where: i.status == :active)

# Conditionally add more filters
query = if exclude_id do
  from([i] in query, where: i.id != ^exclude_id)
else
  query
end

Repo.all(query)
```

---

## 10. GenServer — Stateful Processes

This is the biggest conceptual leap. In Java/C#, you have objects with mutable state, protected by locks. In Elixir, **each stateful thing is a separate OS-lightweight process** with a message queue.

A GenServer is like a thread-safe singleton service with an inbox.

### The Java/C# equivalent (conceptual)

```csharp
// C# — thread-safe service
public class EmbeddingPool {
    private readonly object _lock = new();
    private List<(TaskCompletionSource<float[]>, string)> _queue = new();

    public async Task<float[]> GetEmbedding(string text) {
        var tcs = new TaskCompletionSource<float[]>();
        lock (_lock) {
            _queue.Add((tcs, text));
            if (_queue.Count >= 20) FlushQueue();
        }
        return await tcs.Task;
    }
}
```

### The Elixir version

```elixir
# lib/cerno/embedding/pool.ex
defmodule Cerno.Embedding.Pool do
  use GenServer

  @batch_size 20
  @flush_interval_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API (runs in the CALLER's process) ---

  def get_embedding(text, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:embed, text}, timeout)
  end

  # --- Server callbacks (runs in the GenServer's process) ---

  @impl true
  def init(_opts) do
    schedule_flush()
    {:ok, %{queue: [], timer_ref: nil}}
  end

  @impl true
  def handle_call({:embed, text}, from, state) do
    queue = [{from, text} | state.queue]

    if length(queue) >= @batch_size do
      flush_queue(queue)
      {:noreply, %{state | queue: []}}
    else
      {:noreply, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    if state.queue != [] do
      flush_queue(state.queue)
    end
    schedule_flush()
    {:noreply, %{state | queue: []}}
  end
end
```

Key concepts:

| GenServer concept | Java/C# equivalent |
|---|---|
| `handle_call` | Synchronous method call (caller blocks for reply) |
| `handle_cast` | Fire-and-forget (`void` async method) |
| `handle_info` | Handling a timer tick or system event |
| `state` (second arg) | Instance fields, but immutable — return new state |
| `from` | The caller's return address (like `TaskCompletionSource`) |
| `GenServer.reply(from, value)` | `tcs.SetResult(value)` |
| `{:noreply, new_state}` | "I'll reply later / I already replied / this was cast" |

**No locks needed.** Messages are processed one at a time. The process's state is only accessible inside its callbacks.

---

## 11. Supervision Trees — Let It Crash

In Java/C# you write defensive code and try to handle every error. In Elixir, you structure your system so that crashes are **safe and recoverable**.

```elixir
# lib/cerno/application.ex
def start(_type, _args) do
  children = [
    Cerno.Repo,                                          # Database pool
    {Phoenix.PubSub, name: Cerno.PubSub},                # Event bus
    Cerno.Embedding.Pool,                                # Batching service
    Cerno.Embedding.Cache,                               # Cache service
    {Registry, keys: :unique, name: Cerno.Watcher.Registry},
    {DynamicSupervisor, name: Cerno.Watcher.Supervisor}, # Spawns watchers on demand
    {Task.Supervisor, name: Cerno.Process.TaskSupervisor},
    Cerno.Process.Accumulator,                           # Core pipeline
    Cerno.Process.Reconciler,
    Cerno.Process.Organiser,
    Cerno.Process.Resolver
  ]

  opts = [strategy: :one_for_one, name: Cerno.Supervisor]
  Supervisor.start_link(children, opts)
end
```

- `strategy: :one_for_one` — if a child crashes, restart **only that child**
- Each child is a GenServer (or similar process) that gets restarted from scratch with clean state
- This is like a service orchestrator that auto-restarts failed microservices

**DynamicSupervisor** is for children created at runtime (e.g., one FileWatcher per watched project — like a `ConcurrentDictionary<string, FileWatcher>` that auto-restarts entries).

**Task.Supervisor** manages short-lived background work:

```elixir
# lib/cerno/process/accumulator.ex:58-66
Task.Supervisor.start_child(Cerno.Process.TaskSupervisor, fn ->
  try do
    run_accumulation(path)
  rescue
    e -> Logger.error("Accumulation failed: #{inspect(e)}")
  after
    GenServer.cast(__MODULE__, {:done, path})
  end
end)
```

If this task crashes, the TaskSupervisor handles it — the Accumulator GenServer is unaffected.

---

## 12. PubSub — Decoupled Communication

Instead of direct method calls between services, Cerno's processes communicate through a publish-subscribe event bus.

```csharp
// C# — direct coupling
accumulator.OnComplete += (path) => reconciler.Run(path);
```

```elixir
# Elixir — subscribe in init (lib/cerno/process/accumulator.ex:46)
def init(_opts) do
  Phoenix.PubSub.subscribe(Cerno.PubSub, "file:changed")
  {:ok, %{processing: MapSet.new()}}
end

# Handle the event (lib/cerno/process/accumulator.ex:98)
def handle_info({:file_changed, path}, state) do
  accumulate(path)
  {:noreply, state}
end

# Publish when done (lib/cerno/process/accumulator.ex:88)
Phoenix.PubSub.broadcast(Cerno.PubSub, "accumulation:complete", {:accumulation_complete, path})
```

The Accumulator doesn't know who's listening. The Reconciler subscribes to `"accumulation:complete"` in its own `init/1`. Neither process holds a reference to the other.

---

## 13. Enum, Captures, and Closures

`Enum` is Elixir's LINQ / Java Streams. All collection operations go through it.

### Anonymous functions

```elixir
Enum.map(fragments, fn fragment ->
  {fragment.section_heading, fragment}
end)
```

Equivalent to `fragments.Select(f => (f.SectionHeading, f))`.

### The capture operator `&`

Short-hand for simple functions:

```elixir
# Full form
Enum.map(parsers(), fn p -> p.file_pattern() end)

# Capture form — & creates a function, &1 is the first argument
Enum.map(parsers(), & &1.file_pattern())
```

Referencing a named function:

```elixir
# Full form
Enum.reject(items, fn x -> is_nil(x) end)

# Capture a named function
Enum.reject(items, &is_nil/1)
```

`&is_nil/1` means "a reference to the `is_nil` function with arity 1."

### Common Enum operations

| C# LINQ | Elixir Enum |
|---|---|
| `.Select(x => ...)` | `Enum.map(list, fn x -> ... end)` |
| `.Where(x => ...)` | `Enum.filter(list, fn x -> ... end)` |
| `.Aggregate(seed, (acc, x) => ...)` | `Enum.reduce(list, seed, fn x, acc -> ... end)` |
| `.SelectMany(x => ...)` | `Enum.flat_map(list, fn x -> ... end)` |
| `.Count(x => ...)` | `Enum.count(list, fn x -> ... end)` |
| `.First()` | `List.first(list)` or `Enum.at(list, 0)` |
| `.Take(n)` | `Enum.take(list, n)` |
| `.OrderByDescending(x => x.Score)` | `Enum.sort_by(list, fn x -> x.score end, :desc)` |
| `.Distinct()` | `Enum.uniq(list)` |
| `.ToDictionary(x => x.Key, x => x.Val)` | `Enum.into(list, %{})` or `Map.new(list, fn x -> ... end)` |
| `.GroupBy(x => x.Key)` | `Enum.group_by(list, fn x -> x.key end)` |
| `.Any(x => ...)` | `Enum.any?(list, fn x -> ... end)` |

Real example — `Enum.reduce` accumulating stats:

```elixir
# lib/cerno/process/accumulator.ex:221-229
Enum.reduce(learnings, %{insights_created: 0, insights_updated: 0}, fn learning, stats ->
  case ingest_learning(learning, source_fragment) do
    :created -> %{stats | insights_created: stats.insights_created + 1}
    :updated -> %{stats | insights_updated: stats.insights_updated + 1}
    :error -> stats
  end
end)
```

This is like `Aggregate` in C# — start with `{0, 0}`, walk each learning, return a new stats map. Pattern matching in the `case` determines which counter to increment.

---

## 14. Module Attributes — Constants and Metadata

Module attributes (`@name value`) serve multiple purposes:

### Compile-time constants (like `const` or `static readonly`)

```elixir
# lib/cerno/embedding/pool.ex:11-12
@batch_size 20
@flush_interval_ms 500
```

### Documentation

```elixir
@moduledoc """
GenServer that batches embedding requests for efficiency.
"""

@doc "Request an embedding."
def get_embedding(text), do: ...
```

`@moduledoc` and `@doc` are built into the language and power `mix docs` (like XML doc comments or Javadoc).

### Computed constants (evaluated at compile time)

```elixir
# lib/cerno/short_term/classifier.ex:43-72
@category_signals %{
  warning: ["never", "don't", "avoid", ...],
  convention: ["always", "convention", "naming", ...],
  # ...
}
```

This map is built once at compile time, not at each function call. You can even compute attributes from other attributes:

```elixir
@negation_pairs [{"always", "never"}, {"use", "avoid"}, ...]

@negation_regexes Enum.map(@negation_pairs, fn {pos, neg} ->
  {Regex.compile!("\\b#{pos}\\b", "i"), Regex.compile!("\\b#{neg}\\b", "i")}
end)
```

The regexes are compiled once at build time, not at runtime.

### Typespecs

```elixir
@type classification :: %{
  category: atom(),
  tags: [String.t()],
  domain: String.t() | nil
}

@spec classify(String.t() | map()) :: classification()
```

These are checked by Dialyzer (a static analysis tool), not at runtime. They're documentation that the toolchain can verify.

---

## 15. Keyword Lists — Ordered Options Bags

Keyword lists are a common pattern for optional function parameters — like `params` dictionaries or option objects.

```csharp
// C#
public List<(Insight, float)> FindSimilar(
    float[] embedding,
    float threshold = 0.92f,
    int limit = 10,
    int? excludeId = null)
```

```elixir
# lib/cerno/short_term/insight.ex:83-87
def find_similar(embedding, opts \\ []) do
  threshold = Keyword.get(opts, :threshold, 0.92)
  limit = Keyword.get(opts, :limit, 10)
  exclude_id = Keyword.get(opts, :exclude_id, nil)
  status = Keyword.get(opts, :status, :active)
  # ...
end
```

Called as:

```elixir
Insight.find_similar(embedding, threshold: 0.8, limit: 5)
```

The `[threshold: 0.8, limit: 5]` syntax is a keyword list — a list of `{atom, value}` tuples. When it's the last argument to a function, the brackets are optional, making it look like named parameters.

`opts \\ []` means "default to an empty list if not provided."

---

## 16. Concurrency With Task

`Task` is Elixir's equivalent of `Task<T>` in C#, but backed by lightweight processes instead of thread pool threads.

### Fire-and-forget (supervised)

```elixir
# lib/cerno/process/accumulator.ex:58
Task.Supervisor.start_child(Cerno.Process.TaskSupervisor, fn ->
  run_accumulation(path)
end)
```

Like `Task.Run(() => RunAccumulation(path))` but supervised — if it crashes, the supervisor knows.

### Async with timeout

```elixir
# lib/cerno/llm/claude_cli.ex
task = Task.async(fn ->
  output = :os.cmd(shell_cmd) |> List.to_string()
  {output, 0}
end)

case Task.yield(task, @cli_timeout_ms) || Task.shutdown(task, :brutal_kill) do
  {:ok, {output, 0}} -> {:ok, output}
  {:ok, {output, exit_code}} -> {:error, {:exit_code, exit_code, output}}
  nil -> {:error, :timeout}
end
```

- `Task.async` — starts work, returns a handle
- `Task.yield(task, timeout)` — wait up to N ms for a result
- `Task.shutdown(task, :brutal_kill)` — kill it if it didn't finish
- The `||` chain means: "try yield; if it returns nil (timeout), shut it down"

---

## Quick Reference: Syntax Cheat Sheet

| Elixir | Java/C# | Notes |
|---|---|---|
| `:atom` | Enum value / interned string | Lightweight constant. `:ok`, `:error`, `:active` |
| `"string #{expr}"` | `$"string {expr}"` | String interpolation |
| `[1, 2, 3]` | `List<int>` | Linked list (not array) |
| `{:ok, val}` | `(ResultStatus.Ok, val)` | Tuple — fixed-size, mixed types |
| `%{key: val}` | `Dictionary<K,V>` | Map — the go-to key-value structure |
| `%Struct{...}` | `new MyClass(...)` | Struct creation |
| `defp` | `private` method | `def` = public, `defp` = private |
| `alias Mod` | `using Mod` | Shortens `Cerno.ShortTerm.Insight` to `Insight` |
| `import Mod` | `using static Mod` | Brings functions into current scope |
| `require Mod` | N/A | Needed for compile-time macros |
| `inspect(term)` | `.ToString()` | Debug representation of any value |
| `# comment` | `// comment` | |
| `nil` | `null` | |
| `true`, `false` | `true`, `false` | Atoms, not a separate bool type |
