## Short term
- Add linting
- Only show either launch or stop button for a workspace depending on the state. not both. 
- Allow attaching an already open window to a running workspace so it is included when looping through windows of the workspace
- When creating a new workspace for git projects, let users choose a target branch (default to main/master). Newly created branch should be based on the latest commit of the selected target branch.
- Workspace should inherit settings from the project it is based on when it is first created but they can be overrriden e.g. once a workspace is created, it starts with the list of processes and browser sessions defined by the project but user can update, remove or add to it
- Better indicators for statuses
- When the app opens, left panel is small but its size changes depending on content of the right panel. its size should only change if user drags the divider. Make the starting size of the left panel larger by 50%.
- Make archive button red. Move it to the bottom of the workspace detail view. Require confirmation.
- Show keyboard shortcuts inline if possible, otherwise in the app footer for reference
- Show autocomplete for ENV variables when editing a process command, or setup script or cleanup script

## Medium term
- Make a plan for updating the app after the initial release
- Make a plan for selling licenses

## Long term
- Integrate with GitHub for creating pull requests on behalf of users
- AI agents to enhance user workflow (e.g. autogenerate summaries)
    - "run a small haiku bot looking at what I'm doing in any given instance and give me 200 characters on what I seem to be trying to do in a small div above my input box"