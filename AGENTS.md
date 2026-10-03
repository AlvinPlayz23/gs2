Working Directory Restriction

Agents MUST work only within the assigned working directory for this task.

Agents MUST NOT:

Navigate to, inspect, list, read, modify, create, delete, execute, or otherwise interact with the user's home directory.

Navigate to, inspect, list, read, modify, create, delete, execute, or otherwise interact with any folder or file outside the assigned working directory.

Run commands from, against, or targeting paths outside the assigned working directory.

Change the working directory to any location outside the assigned working directory.

Permission Required for Any Exception

If a task requires accessing, navigating, reading, writing, creating, deleting, executing, or running commands against anything outside the assigned working directory, the agent MUST:

STOP the current request immediately.

Do not attempt the external action, including as a workaround or through an indirect path.

Ask the user for explicit permission to access the specific external path or location and explain why it is required.

Resume only after the user has granted permission.

Silence, ambiguity, or an implied need for access does NOT count as permission.

Default Rule

When there is any doubt about whether a path is inside the assigned working directory, treat it as outside the allowed scope and STOP to ask the user before proceeding.