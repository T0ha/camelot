# Feature Implementation Flow

- Plan the feature and ask for feedback
- Create a new branch from `main` for the feature
- Implement tests first (TDD) and ask for approve
- Implement the feature code
- Make sure code is compilable by `mix compile` and has no warnings
- Run all tests with `mix test` and ensure they pass
- Make sure code runs in `iex -S mix` without errors
- Check with `mix dialyzer` for type issues
- Update documentation and AGENTS.md if needed
- Run `mix format` to ensure code style compliance
- Create a pull request and ask for review
- Address any feedback from the review

