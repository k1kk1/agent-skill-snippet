# Security policy

## Scope and data flow

Agent Recipes is a local macOS application. It reads Recipes, Projects, history,
and Settings from the user's Application Support directory. It can also read the
system clipboard when a Recipe uses `{{clipboard}}` or enables the Clipboard
default for an argument.

When a user runs a `paste` or `submit` Recipe, the generated Prompt is passed to
the locally installed `herdr` CLI. Herdr and the selected coding agent may then
send that content to their configured external services. Treat clipboard text,
Prompt variables, Project names, and working-directory paths as potentially
sensitive before running a Recipe.

The application does not include analytics or its own network client. This does
not change the data handling of Herdr, the selected agent, or the services those
tools use.

## Local storage

- Recipe bodies are stored in `prompt.md` under the configured Recipe directory.
- History deliberately excludes Prompt bodies and argument values.
- Debug logging is off by default. Enable it only while troubleshooting and
  review or remove `debug.log` afterwards.

Do not commit `~/Library/Application Support/AgentRecipes/`, custom Recipes with
confidential prompts, copied Skills, logs, or screenshots containing sensitive
information.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability or an accidental
data disclosure. Contact the repository owner privately using the contact method
listed in the repository profile, including:

- affected version and macOS version;
- steps to reproduce;
- impact and any suggested mitigation.

The maintainer will acknowledge the report, assess the impact, and coordinate a
fix before public disclosure.
