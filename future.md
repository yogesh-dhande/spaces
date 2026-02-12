
## Now
- Write more tests to increase test coverage. Always consider adding tests before finalizing changes. Add instruction to AGENTS.md





## Short term
### Core functionality
- Do not use cmd+shift+number for window shortcuts. Use cmd+number instead.
- Allow users to override default keyboard shortcuts for actions in the settings.

- When creating a new workspace for git projects, let users choose a target branch (default to main/master). Newly created branch should be based on the latest commit of the selected target branch.
- Workspaces should have a user-supplied name which defaults to the folder name when creating a new workspace


- Clarify and fix behavior when workspace is considered as "running" but some processes or windows are not open or not tracked or closed by the user. Should launch button them bring them back to life? Should we hide the launch button and show a "restart" button to clarify the action?
- When a workspace is stopped, ensure that we stop the processes before closing the respective terminal windows to avoid any orphaned and untracked processes.
- Left panel should show folder name for workspaces (and branch name next to it)


- Move status checks below the processes. Can we nest them under the process they apply to so we don't need to input which process they apply to when creating.

- Add a chrome profile setting to project. Use that when opening browser sessions for workspaces of that project.


### UI fixes
- Remove settings button row from the left panel. The gear icon in the top header is sufficient.
- Apply color palette to the app
- Better indicators for statuses
- Make archive button red. Move it to the bottom of the workspace detail view. Require confirmation.
- Show keyboard shortcuts inline if possible, otherwise in the app footer for reference
- Allow attaching an already open window to a running workspace so it is included when looping through windows of the workspace. Also allow detaching windows. Keep reference to them (as "known windows") so the user can reattach them quickly from the GUI


### Medium term
- Make a plan for updating the app after the initial release
- Make a plan for selling licenses

### Long term
- UX: Show autocomplete for ENV variables when editing a process command, or setup script or cleanup script
- Functionality: Integrate with GitHub for creating pull requests on behalf of users
- UX: AI agents to enhance user workflow (e.g. autogenerate summaries)
    - "run a small haiku bot looking at what I'm doing in any given instance and give me 200 characters on what I seem to be trying to do in a small div above my input box"