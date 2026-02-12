
## Now

## Short term
### Core functionality


- What happens when workspace is considered as "running" but some processes or windows are not open or not tracked or closed by the user. Should launch button them bring them back to life? Should we hide the launch button and show a "restart" button to clarify the action?
- When a workspace is stopped, ensure that we stop the processes before closing the respective terminal windows to avoid any orphaned and untracked processes.



- In project creation form and in workspace settings form, can we nest status checks under the process they apply to so we don't need to specify which process they apply to when creating them?

- Clarify what happens when workspace is archived. We should definitely stop all processes and close all windows. Should we show options to the user to (1) delete the workspace dir (default to true) (2) delete the git branch locally (default to true) (3) delete the git branch on remote (default to false)

- Add a default chrome profile setting. Also add to project settings (initialize with settings default) but user can change when creating a new project or editing an existing project. Use that profile when opening browser sessions for workspaces of that project.


### UI fixes
- Apply color palette to the app
- Better indicators for statuses
- Make archive button red. Move it to the bottom of the workspace detail view. Require confirmation.
- Show keyboard shortcuts inline if possible, otherwise in the app footer for reference
- Allow attaching an already open window to a running workspace so it is included when looping through windows of the workspace. Also allow detaching windows. Keep reference to them (as "known windows") so the user can reattach them quickly from the GUI


