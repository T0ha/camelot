# PR Issues Fixing Flow

**Never fix files in `.claude` directory! **

- Checkout the branch related to the PR
- Fix critical issues from the comments and review in the PR
- Make sure code is compilable by `mix compile` and has no warnings
- Run all tests with `mix test` and ensure they pass
- Make sure code runs in `iex -S mix` without errors
- Check with `mix dialyzer` for type issues
- Run `mix format` to ensure code style compliance
- Commit code
- Push branch to remote
- Create a pull request

