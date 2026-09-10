## Coding Style

# Elixir Style Guide
Follow: https://github.com/christopheradams/elixir_style_guide

# OTP Design Principles
Follow: [OTP design principles](https://www.erlang.org/doc/system/design_principles.html)

- Use `with` for handling multiple operations that may fail
- Use pipe operator (|>) for chaining
- Prefer simple functions with patterns matching over complex ones
- Limit line length to 80 characters
- Prefer case statements for multi-branch conditionals
- Always create typespecs for public functions but avoid `any()` and `term()` types when possible
- Use descriptive function names with ? suffix for boolean functions
- Don't mix Ash DSL with functions in the same module, separate them into different modules
- Don't use type guards in function heads, use pattern matching instead
- Don't use type guards to check spec. Dialyzer should be used for that
- Use existing phoenix components instead of creating new ones when possible
- Reuse existig already defined functions instead of creating new ones when possible
- Try to avoid `if`,  `cond` and `unless` statements, use pattern matching in functions and case statements instead


# Docs
- Put all `.md` files except `README` and `AGENTS` in `docs/` folder
- Use `@doc` and `@moduledoc` for inline documentation

