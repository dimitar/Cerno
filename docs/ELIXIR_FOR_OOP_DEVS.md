# Elixir for Java/C# Developers

A guide to reading and contributing to this codebase if you're coming from an object-oriented background. Every concept is illustrated with real examples from Cerno.

---

## Table of Contents

1. [Building Blocks: Syntax You'll See Everywhere](#1-building-blocks-syntax-youll-see-everywhere)
2. [Modules Are Not Classes](#2-modules-are-not-classes)
3. [Data Is Immutable — Always](#3-data-is-immutable--always)
4. [Pattern Matching Replaces if/switch/overloads](#4-pattern-matching-replaces-ifswitchoverloads)
5. [The Pipeline Operator (`|>`)](#5-the-pipeline-operator-)
6. [Enum and Anonymous Functions](#6-enum-and-anonymous-functions)
7. [Tagged Tuples Instead of Exceptions](#7-tagged-tuples-instead-of-exceptions)
8. [`with` Chains — Controlled Early Return](#8-with-chains--controlled-early-return)
9. [Structs — Not Objects](#9-structs--not-objects)
10. [Module Attributes — Constants and Metadata](#10-module-attributes--constants-and-metadata)
11. [Keyword Lists — Ordered Options Bags](#11-keyword-lists--ordered-options-bags)
12. [Behaviours — Elixir's Interfaces](#12-behaviours--elixirs-interfaces)
13. [Ecto — The ORM That Isn't](#13-ecto--the-orm-that-isnt)
14. [GenServer — Stateful Processes](#14-genserver--stateful-processes)
15. [Supervision Trees — Let It Crash](#15-supervision-trees--let-it-crash)
16. [PubSub — Decoupled Communication](#16-pubsub--decoupled-communication)
17. [Concurrency With Task](#17-concurrency-with-task)

---

## 1. Building Blocks: Syntax You'll See Everywhere

Before diving into concepts, here are the basic syntax pieces that show up in almost every Elixir file. Skim this section now, and come back to it when you see something unfamiliar later.

### Atoms

Atoms are constant labels that start with a colon. They're like enum values in C#, except you don't need to declare them anywhere — you just use them.

```elixir
:ok
:error
:active
:unchanged
```

They're used everywhere: as return status (`:ok`, `:error`), as map keys (`:content`, `:status`), and as options (`:desc`, `:asc`). If you see a colon followed by a word, that's an atom.

In C# you might write `Status.Active` — in Elixir you'd just write `:active`.

### `do...end` blocks

In C# you use curly braces `{ }` to wrap a block of code. In Elixir, you use `do...end`:

```csharp
// C#
public int Add(int a, int b) {
    return a + b;
}
```

```elixir
# Elixir
def add(a, b) do
  a + b
end
```

The last expression in a block is automatically the return value — there's no `return` keyword.

### One-liner shorthand with `do:`

For short functions, Elixir has a compact form using a comma and `do:` instead of a `do...end` block:

```elixir
# These two are identical:

def dimension do
  1536
end

def dimension, do: 1536
```

You'll see this throughout the codebase for simple one-line functions.

### `def` vs `defp` — public vs private

```elixir
def parse(path) do    # public — can be called from outside this module
  # ...
end

defp find_parser(filename) do    # private — only callable within this module
  # ...
end
```

This is the equivalent of `public` vs `private` in C#.

### List prepend with `[head | tail]`

The `|` operator inside square brackets puts items at the front of a list:

```csharp
// C# — add to front of list
queue.Insert(0, newItem);
```

```elixir
# Elixir — create a new list with new_item at the front
queue = [new_item | queue]
```

Since data is immutable (covered in section 3), this doesn't modify the original list — it creates a new one.

You'll also see `|` used to pull apart a list:

```elixir
[first | rest] = [1, 2, 3]
# first = 1, rest = [2, 3]
```

### `use` — injecting code from another module

`use` is **not** the same as `using` in C#. It runs code from another module that adds functions and behaviour to your module at compile time:

```elixir
defmodule MyServer do
  use GenServer    # adds default GenServer callback implementations
  # ...
end
```

Think of it like inheriting a base class that gives you starter code, except it happens through code generation rather than inheritance. You'll see `use GenServer`, `use Ecto.Schema`, and similar throughout the codebase.

---

## 2. Modules Are Not Classes

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

There's no object. `parse/1` takes the data it needs as an argument. The `/1` notation means "function named `parse` that takes 1 argument" — Elixir identifies functions by both their name **and** how many arguments they take. So `parse/1` and `parse/2` are considered two different functions.

---

## 3. Data Is Immutable — Always

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

**So what happens to the old value?** It stays in memory, unchanged. If nothing else references it, the garbage collector cleans it up. If something *does* still reference it (another variable, another process), they still see the original value. This is the big difference from C#/Java:

```csharp
// C# — mutation affects everyone holding a reference
var list = sharedList;
sharedList.Add("x");
// list ALSO sees "x" — it's the same object in memory
```

```elixir
# Elixir — rebinding only affects this name
list = shared_list
shared_list = shared_list ++ ["x"]
# list still has the ORIGINAL value — shared_list now points to a new list
```

This is why Elixir doesn't need locks for concurrency: if you send data to another process, nobody can change it out from under them.

**Map update syntax:**
- `%{map | key: value}` — update existing keys (crashes if the key isn't already in the map)
- `Map.put(map, key, value)` — insert a new key or update an existing one

---

## 4. Pattern Matching Replaces if/switch/overloads

This is the single biggest mental shift. Pattern matching is used **everywhere**: function definitions, `case`, `with`, and plain `=`.

**Why is this better than if/switch?** Pattern matching checks the shape of data and pulls out the values you need in one step. In C# you'd check a condition, then separately extract values — pattern matching does both at once. It also means you can't accidentally access data without first confirming it's the right shape. For example, you can't get at the `value` inside `{:ok, value}` without first matching on `:ok` — the error case can't sneak past you. And when you define multiple versions of the same function with different patterns, anyone reading the code can immediately see every case that's handled, without scrolling through a long switch block.

### Multiple versions of the same function (like method overloading, but matching on values)

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

Elixir tries each version **top to bottom** until one matches. The first version looks for a map that has both `:content` and `:section_heading` keys — it pulls those values out into variables in one step. The second version matches any plain string. The `when is_binary(content)` part is called a **guard** — it's an extra condition that must be true for the match to succeed. (In Elixir, "binary" just means "string".)

### Pulling apart values in `case`

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

Each `->` branch is a pattern. `{:changed, file_hash}` does two things at once: it checks that the value is a two-item pair starting with `:changed`, **and** saves the second item into a variable called `file_hash`.

### Pulling apart values in `=`

```elixir
# lib/cerno/process/accumulator.ex:344
{line_start, line_end} = fragment.line_range || {0, 0}
```

This is like `var (lineStart, lineEnd) = ...;` in C# — it splits a pair into two separate variables. In Elixir, this works on any data shape, not just tuples.

---

## 5. The Pipeline Operator (`|>`)

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

Read it top to bottom: start with `scored`, filter it, sort it, take N. The `_p` prefix means "this variable exists in the pattern but I don't actually use it" — the underscore tells Elixir (and other developers) to ignore it.

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

Don't worry about the `&` shorthand in this example — that's covered in the next section.

---

## 6. Enum and Anonymous Functions

`Enum` is Elixir's version of LINQ (C#) or Java Streams. All list/collection operations go through it.

### Anonymous functions

```elixir
Enum.map(fragments, fn fragment ->
  {fragment.section_heading, fragment}
end)
```

Equivalent to `fragments.Select(f => (f.SectionHeading, f))`.

`fn ... -> ... end` is how you write a lambda / anonymous function. It's the same idea as `x => ...` in C#, just with different syntax.

### The `&` shorthand

For simple functions, there's a shorter way to write them:

```elixir
# Full form
Enum.map(parsers(), fn p -> p.file_pattern() end)

# Short form — & creates a function, &1 is the first argument
Enum.map(parsers(), & &1.file_pattern())
```

You can also reference an existing function by name:

```elixir
# Full form
Enum.reject(items, fn x -> is_nil(x) end)

# Short form — reference the is_nil function directly
Enum.reject(items, &is_nil/1)
```

`&is_nil/1` means "a reference to the `is_nil` function that takes 1 argument." It's like passing a method group in C# (`items.Where(string.IsNullOrEmpty)`).

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

This is like `Aggregate` in C# — start with `{0, 0}`, go through each learning one by one, and build up a new stats map. The `case` checks what happened and bumps the right counter.

---

## 7. Tagged Tuples Instead of Exceptions

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

The pattern is the same everywhere:
- `{:ok, value}` — it worked, here's the result
- `{:error, reason}` — it failed, here's why
- Simple labels like `:ok` or `:unchanged` when no extra data is needed

Functions spell out what they return in their **type signatures**:

```elixir
# lib/cerno/embedding.ex:13
@callback embed(text :: String.t()) :: {:ok, embedding()} | {:error, term()}
```

This says: "embed returns either `{:ok, embedding}` or `{:error, something}`." The caller **must** handle both cases — there's no hidden exception that might slip through.

---

## 8. `with` Chains — Controlled Early Return

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

Each `<-` line checks whether the result matches the expected pattern. If any line doesn't match (e.g., `{:error, reason}` comes back instead of `{:ok, ...}`), the whole `with` block stops early and returns that failed value. No nesting, no error handling at each step.

### Handling specific errors with `else`

By default, `with` returns whatever value didn't match. If you want to handle specific failure cases differently, add an `else` block:

```elixir
with {:ok, decoded} <- decode_json(json_string),
     {:ok, result} <- extract_result(decoded) do
  {:ok, normalize_learnings(result)}
else
  {:error, :invalid_json} ->
    Logger.error("Bad JSON input")
    {:error, :parse_failure}

  {:error, reason} ->
    Logger.error("Failed: #{inspect(reason)}")
    {:error, reason}
end
```

The `else` branches work just like `case` — each `->` is a pattern that matches against whatever value caused the `with` to stop early.

---

## 9. Structs — Not Objects

A struct is like a map, but with a fixed set of fields and a name. Unlike objects in Java/C#, structs have no methods, no constructors, and no inheritance.

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

- `@enforce_keys` — your code won't compile if you create a struct without these fields (like `required` in C#)
- `defstruct` — lists all the fields the struct can have
- `build_id/2` — just a regular function that lives in the same module; it doesn't belong to any particular Fragment

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

**Type specs** describe what each field holds:

```elixir
@type t :: %__MODULE__{
  id: String.t(),
  content: String.t(),
  section_heading: String.t() | nil,
  line_range: {non_neg_integer(), non_neg_integer()},
  # ...
}
```

`__MODULE__` is automatically replaced with the current module's name at compile time (like `typeof(this).Name` in C#).

---

## 10. Module Attributes — Constants and Metadata

Module attributes (`@name value`) are used for several things:

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

### Pre-calculated values (built once when the code compiles)

```elixir
# lib/cerno/short_term/classifier.ex:43-72
@category_signals %{
  warning: ["never", "don't", "avoid", ...],
  convention: ["always", "convention", "naming", ...],
  # ...
}
```

This map is built once when the code compiles, not every time a function runs. You can even build one attribute from another:

```elixir
@negation_pairs [{"always", "never"}, {"use", "avoid"}, ...]

@negation_regexes Enum.map(@negation_pairs, fn {pos, neg} ->
  {Regex.compile!("\\b#{pos}\\b", "i"), Regex.compile!("\\b#{neg}\\b", "i")}
end)
```

The regex patterns are built once when the code compiles, so they don't slow things down when the program runs.

### Typespecs — optional but useful type annotations

Elixir is dynamically typed — there's no compiler enforcing types like in C# or Java. But you can **optionally** add type annotations:

```elixir
@type classification :: %{
  category: atom(),
  tags: [String.t()],
  domain: String.t() | nil
}

@spec classify(String.t() | map()) :: classification()
```

`@type` defines a named type (like `typedef` or a C# type alias). `@spec` declares what a function takes and returns — read the one above as: "classify takes a string or a map and returns a classification."

**Why bother if they're not enforced?**

1. **Documentation for your teammates.** When you're reading unfamiliar code, `@spec find_similar(list(), keyword()) :: list()` tells you what a function expects and returns at a glance — no need to read the implementation.
2. **Editor support.** Tools like ElixirLS (the VSCode extension) use specs to give you autocomplete and hover info, similar to IntelliSense in Visual Studio.
3. **Catching bugs with Dialyzer.** Dialyzer is a static analysis tool (run via `mix dialyzer`) that reads your specs and checks whether your code actually matches them. It won't catch everything a C# compiler would, but it does find real bugs — like passing a string where a list is expected, or a function that claims to return `{:ok, value}` but sometimes returns `:error` instead.

**When to write them:**
- On public functions (`def`) — especially the ones other modules call
- On behaviour callbacks (`@callback`) — so implementations know what to match
- On custom types that show up in multiple places

**When to skip them:**
- On private helper functions (`defp`) that are only called internally — the cost of maintaining the spec usually outweighs the benefit
- On very simple functions where the name already makes it obvious (e.g., `defp to_lowercase(str)`)

In this codebase, you'll see specs on most public APIs and behaviour callbacks, but not on every private function.

---

## 11. Keyword Lists — Ordered Options Bags

Keyword lists are a common way to pass optional settings to a function — similar to option objects or dictionaries of parameters.

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

The `[threshold: 0.8, limit: 5]` syntax is a keyword list — basically a list of name-value pairs. When it's the last argument to a function, the square brackets are optional, making it look like named parameters.

`opts \\ []` means "if no options are passed in, use an empty list as the default."

---

## 12. Behaviours — Elixir's Interfaces

Behaviours are Elixir's version of `interface` in Java/C#. They define a set of functions that any implementing module **must** provide.

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

`@impl true` is a marker that tells the compiler "this function is required by a behaviour." If the function name or arguments don't match what the behaviour expects, you'll get a warning when you compile.

Note: `def dimension, do: 1536` is the one-liner shorthand covered in [section 1](#1-building-blocks-syntax-youll-see-everywhere). It's identical to writing `def dimension do 1536 end`.

**Choosing the implementation at runtime** (without inheritance):

```elixir
# lib/cerno/embedding.ex:23-24
def provider do
  Application.get_env(:cerno, :embedding)[:provider] || Cerno.Embedding.OpenAI
end

def embed(text), do: provider().embed(text)
```

The provider module is loaded from a config file. `provider().embed(text)` calls `embed` on whatever module is configured — OpenAI in production, a fake (Mock) in tests. This is how Elixir does dependency injection: swap the module in config instead of passing it through a constructor.

---

## 13. Ecto — The ORM That Isn't

Ecto looks like Entity Framework or Hibernate, but works differently: there's no lazy loading, no automatic change tracking, and no hidden SQL. You always say exactly what you want to happen.

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

`~w(active contradicted)a` is a shortcut for writing `[:active, :contradicted]` (a list of atoms). The `~w(...)` splits words by spaces, and the `a` at the end turns them into atoms.

### Changeset = A Proposed Change with Validation

There's no `insight.Content = "new"` followed by `db.SaveChanges()`. Instead, you build a **changeset** — a package that describes what you *want* to change, along with rules that must pass before the change goes through:

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
- `^variable` — the **pin operator** — plugs a variable's value into the query safely (prevents SQL injection)
- `fragment(...)` — lets you write raw SQL for things Ecto doesn't support natively (here: pgvector's `<=>` distance operator)

Queries can be built up piece by piece:

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

## 14. GenServer — Stateful Processes

This is the biggest mental shift. In Java/C#, you have objects with changeable data, protected by locks so multiple threads don't corrupt it. In Elixir, **each piece of data that needs to persist is held by its own lightweight process** with a message queue (like an inbox).

Think of a GenServer as a service that processes requests one at a time from its inbox — no locks needed.

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

Note: `[{from, text} | state.queue]` uses list prepend (covered in [section 1](#1-building-blocks-syntax-youll-see-everywhere)) to add the new request to the front of the queue.

Key concepts:

| GenServer concept | Java/C# equivalent |
|---|---|
| `handle_call` | A request where the caller waits for a response |
| `handle_cast` | A request where the caller doesn't wait ("fire and forget") |
| `handle_info` | Handling a timer tick or system event |
| `state` (second arg) | The process's stored data — you return a new version each time |
| `from` | Who sent the request, so you can reply later |
| `GenServer.reply(from, value)` | Send the response back to the caller |
| `{:noreply, new_state}` | "I'll reply later / I already replied / this was a cast" |

**No locks needed.** Messages are handled one at a time, in order. Only the process itself can see or change its own state.

---

## 15. Supervision Trees — Let It Crash

In Java/C# you write defensive code and try to handle every possible error. In Elixir, you design your system so that crashes are **safe and the system recovers automatically**.

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

- `strategy: :one_for_one` — if one child crashes, restart **only that child**, leave the rest alone
- Each child is a process that gets restarted from scratch with a clean slate
- Think of it like a service manager that automatically restarts any service that goes down

**DynamicSupervisor** is for processes created on the fly (e.g., one FileWatcher per watched project — you can add and remove them at runtime, and they auto-restart if they crash).

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

## 16. PubSub — Decoupled Communication

Instead of services calling each other directly, Cerno's processes communicate by broadcasting and listening for events — like a message board that anyone can post to or read from.

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

The Accumulator doesn't know who's listening. The Reconciler subscribes to `"accumulation:complete"` in its own startup. Neither process knows the other exists — they only know about the topics they care about.

---

## 17. Concurrency With Task

`Task` is Elixir's version of `Task<T>` in C#. The difference: Elixir tasks run in lightweight processes instead of thread pool threads, so you can have thousands of them without problems.

### Start and don't wait (supervised)

```elixir
# lib/cerno/process/accumulator.ex:58
Task.Supervisor.start_child(Cerno.Process.TaskSupervisor, fn ->
  run_accumulation(path)
end)
```

Like `Task.Run(() => RunAccumulation(path))` but watched by a supervisor — if it crashes, the supervisor handles the cleanup.

### Run in the background with a time limit

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

- `Task.async` — starts the work in the background, gives you a handle to check on it
- `Task.yield(task, timeout)` — wait up to N milliseconds for it to finish
- `Task.shutdown(task, :brutal_kill)` — force-stop it if it took too long
- The `||` chain reads: "try to get the result; if it times out (returns nil), kill the task"

---

## Quick Reference: Syntax Cheat Sheet

| Elixir | Java/C# | Notes |
|---|---|---|
| `:atom` | Enum value / interned string | A named label. `:ok`, `:error`, `:active` |
| `"string #{expr}"` | `$"string {expr}"` | String interpolation |
| `[1, 2, 3]` | `List<int>` | Linked list (not array) |
| `[h \| t]` | N/A | Prepend `h` to list `t`, or split a list into head and tail |
| `{:ok, val}` | `(ResultStatus.Ok, val)` | Tuple — fixed-size, mixed types |
| `%{key: val}` | `Dictionary<K,V>` | Map — the go-to key-value structure |
| `%Struct{...}` | `new MyClass(...)` | Struct creation |
| `def` / `defp` | `public` / `private` method | |
| `do...end` | `{ ... }` | Block delimiters |
| `fn x -> x end` | `x => x` | Anonymous function / lambda |
| `&func/1` | Method group reference | Reference to a named function |
| `alias Mod` | `using Mod` | Shortens `Cerno.ShortTerm.Insight` to `Insight` |
| `import Mod` | `using static Mod` | Brings functions into current scope |
| `use Mod` | N/A | Injects code from another module (like inheriting a base class) |
| `require Mod` | N/A | Needed for compile-time macros |
| `inspect(value)` | `.ToString()` | Turns any value into a readable string for debugging |
| `# comment` | `// comment` | |
| `nil` | `null` | |
| `true`, `false` | `true`, `false` | These are actually just atoms, not a separate boolean type |
