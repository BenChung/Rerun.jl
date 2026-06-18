# API Reference

Functions are accessed as `Rerun.f(...)` unless exported. Materialized
component / archetype / enum types live in the `Rerun.Components`,
`Rerun.Archetypes`, and `Rerun.Blueprint` submodules (generated from the Rerun
IDL); bring them into scope with `using Rerun.Components`, etc.

```@contents
Pages = ["api.md"]
Depth = 2
```

## Recording streams

```@autodocs
Modules = [Rerun]
Pages   = ["stream.jl"]
```

## Sinks

```@autodocs
Modules = [Rerun]
Pages   = ["sinks.jl"]
```

## Typed logging

```@autodocs
Modules = [Rerun]
Pages   = ["types.jl"]
```

## Columnar / temporal logging

```@autodocs
Modules = [Rerun]
Pages   = ["columns.jl"]
```

## Helpers

```@autodocs
Modules = [Rerun]
Pages   = ["helpers.jl"]
```

## Utilities & introspection

```@autodocs
Modules = [Rerun]
Pages   = ["util.jl", "Rerun.jl"]
```

## Errors

```@autodocs
Modules = [Rerun]
Pages   = ["errors.jl"]
```
