defmodule Shazam.TaskTemplates do
  @moduledoc "Built-in task templates — presets for common task types."

  @templates [
    %{
      id: "bug_fix",
      name: "Bug Fix",
      icon: "bug_report",
      title_pattern: "Fix: ",
      description_template:
        "## Bug Description\n\n## Steps to Reproduce\n1. \n\n## Expected Behavior\n\n## Actual Behavior\n\n## Acceptance Criteria\n- [ ] Bug is fixed\n- [ ] No regressions introduced\n- [ ] Tests added/updated"
    },
    %{
      id: "new_feature",
      name: "New Feature",
      icon: "add_circle",
      title_pattern: "Feature: ",
      description_template:
        "## Feature Description\n\n## Requirements\n- \n\n## Technical Approach\n\n## Acceptance Criteria\n- [ ] Feature implemented\n- [ ] Tests written\n- [ ] Documentation updated"
    },
    %{
      id: "refactoring",
      name: "Refactoring",
      icon: "build",
      title_pattern: "Refactor: ",
      description_template:
        "## What to Refactor\n\n## Why\n\n## Scope\n- Files/modules affected:\n\n## Acceptance Criteria\n- [ ] Code refactored\n- [ ] All tests pass\n- [ ] No behavior changes"
    },
    %{
      id: "code_review",
      name: "Code Review",
      icon: "rate_review",
      title_pattern: "Review: ",
      description_template:
        "## What to Review\n\n## Focus Areas\n- Code quality\n- Security\n- Performance\n- Test coverage\n\n## Output Format\nProvide a structured review with:\n1. Issues found (critical/major/minor)\n2. Suggestions\n3. Overall assessment"
    },
    %{
      id: "documentation",
      name: "Documentation",
      icon: "description",
      title_pattern: "Docs: ",
      description_template:
        "## What to Document\n\n## Target Audience\n\n## Sections Needed\n- \n\n## Acceptance Criteria\n- [ ] Documentation written\n- [ ] Examples included\n- [ ] Reviewed for accuracy"
    },
    %{
      id: "testing",
      name: "Write Tests",
      icon: "science",
      title_pattern: "Test: ",
      description_template:
        "## What to Test\n\n## Test Types Needed\n- [ ] Unit tests\n- [ ] Integration tests\n- [ ] Edge cases\n\n## Files/Modules to Cover\n\n## Acceptance Criteria\n- [ ] Tests written and passing\n- [ ] Edge cases covered\n- [ ] Good test names/descriptions"
    }
  ]

  def list, do: @templates
  def get(id), do: Enum.find(@templates, &(&1.id == id))
end
