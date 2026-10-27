# Claude Code Install Scripts

Note: Thanks to the original serversathome developer for the script https://github.com/serversathome/claudelxc that was used as a basis for developing these scripts.

Deployer scripts that turn a machine into a fully provisioned Claude Code
development box, run as one normal (non-root) user, plus a use and
best-practices guide for each platform.

## Getting the scripts

The repository is public, so no GitHub login is needed. Either clone the
whole repo onto the target machine:

```bash
git clone https://github.com/solchjg/claude-code-install-scripts.git
cd claude-code-install-scripts
```

or download just the script for your platform, for example the Pi 5 one:

```bash
curl -fsSLO https://raw.githubusercontent.com/solchjg/claude-code-install-scripts/main/Claude_Code_Raspberry_Pi_5_Deployer.sh
```

Swap in any script name from the table below. These scripts run as root and
change a lot of the system, so read the script before you run it, rather than
piping it straight into `sudo bash`. Then run it with the command in the table.

## Scripts

| Script | What it's for | Run |
| --- | --- | --- |
| `Claude_Code_LXC_Deployer_for_Proxmox.sh` | Creates an unprivileged Ubuntu 26.04 LXC container (no Docker) on a Proxmox host with the toolchains, Claude Code, the web UI and the update/health tools. Run on the Proxmox host. | `bash Claude_Code_LXC_Deployer_for_Proxmox.sh` |
| `Claude_Code_Lubuntu_Deployer.sh` | Sets up a Lubuntu 26.04 desktop PC (bare metal or VM) with Claude Code, Claude Desktop (Chat, Code and Cowork) and the dev tools. No containers. | `sudo bash Claude_Code_Lubuntu_Deployer.sh` |
| `Claude_Code_Raspberry_Pi_5_Deployer.sh` | Sets up a Raspberry Pi 5 (4 GB or 8 GB) on 64-bit Raspberry Pi OS or Ubuntu Desktop with Claude Code, Claude Desktop and the dev tools. | `sudo bash Claude_Code_Raspberry_Pi_5_Deployer.sh` |
| `Claude_Code_Raspberry_Pi_4_Deployer.sh` | The Raspberry Pi 4 Model B (8 GB) variant of the Pi 5 deployer, tuned for the Pi 4's boot settings, throttling and slower CPU. | `sudo bash Claude_Code_Raspberry_Pi_4_Deployer.sh` |

Every deployer leaves these tools on the machine: `agentic-setup-user`
(set up or repair the Claude user), `agentic-update` (weekly coordinated
update), `agentic-doctor` (health check) and `agentic-errorlog`
(collects update/health warnings, with optional ntfy push).

The web UI (CloudCLI, port 3001) listens on the machine itself unless you
answer `lan` at deploy. Reach it from your PC with
`ssh -L 3001:localhost:3001 <user>@<ip>` and open `http://localhost:3001`.

## Uninstalling

Run the same script with `--uninstall`, for example
`sudo bash Claude_Code_Lubuntu_Deployer.sh --uninstall`. On Lubuntu and the Pis
it removes what the script set up, asking before it removes the toolchains,
the apt software or the Claude user's data. The user account and /project are
always kept. The LXC version deletes the whole container after you type its
ID a second time. `--help` lists the options; any other option is refused.

## Guides

Each guide comes as Markdown and as a PDF with the same content.

| Guide | Covers |
| --- | --- |
| `Claude_Code_LXC_Use_and_Best_Practices` (.md / .pdf) | Using and maintaining the Proxmox LXC deployment. |
| `Claude_Code_Lubuntu_Use_and_Best_Practices` (.md / .pdf) | Using and maintaining the Lubuntu deployment. |
| `Claude_Code_Raspberry_Pi_Use_and_Best_Practices` (.md / .pdf) | Using and maintaining the Raspberry Pi 4 and Pi 5 deployments. |
