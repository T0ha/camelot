# Feature Implementation Flow

- Create a new branch from `main` for the feature
- Implement tests first (TDD)
- Implement the feature code
- Make sure code is compilable by `mix compile` and has no warnings
- Run all tests with `mix test` and ensure they pass
- Make sure code runs in `iex -S mix` without errors
- Check with `mix dialyzer` for type issues
- Update documentation and AGENTS.md if needed
- Run `mix format` to ensure code style compliance
- Commit code
- Push branch to remote
- Create a pull request

