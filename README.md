# Claude Code Install Scripts

Note: Thanks to the original serversathome developer for the script https://github.com/serversathome/claudelxc.

Deployer scripts that turn a machine into a fully provisioned Claude Code
development box, run as one normal (non-root) user, plus a use and
best-practices guide for each platform.

Clone the repo onto the target machine (Use `gh repo clone` or an authenticated `git clone`), 
then run the script for your platform as root.

```bash
gh repo clone solchjg/claude-code-install-scripts
cd claude-code-install-scripts
```

## Scripts

| Script | What it's for | Run |
| --- | --- | --- |
| `Claude_Code_LXC_Deployer_for_Proxmox.sh` | Creates an Ubuntu 26.04 LXC container on a Proxmox host with the toolchains, Claude Code, the web UI and the update/health tools. Run on the Proxmox host. | `bash Claude_Code_LXC_Deployer_for_Proxmox.sh` |
| `Claude_Code_Lubuntu_Deployer.sh` | Sets up a Lubuntu 26.04 desktop PC (bare metal or VM) with Claude Code, Claude Desktop (Chat, Code and Cowork) and the dev tools. No containers. | `sudo bash Claude_Code_Lubuntu_Deployer.sh` |
| `Claude_Code_Raspberry_Pi_5_Deployer.sh` | Sets up a Raspberry Pi 5 (4 GB or 8 GB) on 64-bit Raspberry Pi OS or Ubuntu Desktop with Claude Code, Claude Desktop and the dev tools. | `sudo bash Claude_Code_Raspberry_Pi_5_Deployer.sh` |
| `Claude_Code_Raspberry_Pi_4_Deployer.sh` | The Raspberry Pi 4 Model B (8 GB) variant of the Pi 5 deployer, tuned for the Pi 4's boot settings, throttling and slower CPU. | `sudo bash Claude_Code_Raspberry_Pi_4_Deployer.sh` |

Every deployer leaves these tools on the machine: `agentic-setup-user`
(set up or repair the Claude user), `agentic-update` (weekly coordinated
update), `agentic-doctor` (health check) and `agentic-errorlog`
(collects update/health warnings, with optional ntfy push).

## Guides

Each guide comes as Markdown and as a PDF with the same content.

| Guide | Covers |
| --- | --- |
| `Claude_Code_LXC_Use_and_Best_Practices` (.md / .pdf) | Using and maintaining the Proxmox LXC deployment. |
| `Claude_Code_Lubuntu_Use_and_Best_Practices` (.md / .pdf) | Using and maintaining the Lubuntu deployment. |
| `Claude_Code_Raspberry_Pi_Use_and_Best_Practices` (.md / .pdf) | Using and maintaining the Raspberry Pi 4 and Pi 5 deployments. |
