# Ram-Altman

**A bash script (and PowerShell port) that writes to Sam Altman once a day to report the RAM he missed.**

Read the sample emails at **[ram-altman.lol](https://ram-altman.lol)**, no install needed.

[![Website: ram-altman.lol](https://img.shields.io/badge/website-ram--altman.lol-0f5a43)](https://ram-altman.lol)
![Global DRAM allocation: quite terrible](https://img.shields.io/badge/global%20DRAM%20allocation-quite%20terrible-red)
![Utilization: maybe 5%](https://img.shields.io/badge/utilization-maybe%205%25-orange)
![Emails: 1 per day](https://img.shields.io/badge/emails-1%20per%20day-blue)
![Written in Bash, not Electron](https://img.shields.io/badge/written%20in-bash%2C%20not%20electron-brightgreen)
![Also in PowerShell](https://img.shields.io/badge/also%20in-PowerShell-5391FE)

## Quick start (Windows / PowerShell)

No clone, no install. This reports the current RAM and sends nothing:

```powershell
irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex
```

The script is [ram-altman.ps1](https://github.com/ndiuky/ram-altman/blob/main/ram-altman.ps1). Once you configure a recipient (see [PowerShell, for the other computers](#powershell-for-the-other-computers)), the same one-liner installs a scheduled task and starts the daily correspondence.

On Linux, keep scrolling to [Installation](#installation-linux--bash) for the bash version.

There is RAM in your computer. Right now. Just sitting there, in a *personal* computer, being personal.

You may have thought of this as "a computer working normally". On a recent episode of [Cheeky Pint](https://gizmodo.com/sam-altman-youre-completely-right-about-ram-im-sorry-for-the-confusion-heres-what-happened-2000835208), the CEO of OpenAI offered another view:

> "From a global allocation perspective, actually, it's quite terrible to have everybody have a bunch of the world's limited supply of DRAM sitting in their own computer"
>
> — Sam Altman

That RAM, he added, is ["being used maybe 5% of the time"](https://www.xda-developers.com/sam-altman-says-its-quite-terrible-that-people-have-ram-in-their-pcs-during-a-shortage/).

Which raised an obvious question for a certain kind of person: *surely someone should be monitoring this?*

So we wrote a script. If your machine has more than 10% of its RAM available, it sends one email a day to let Sam know. It seemed only fair. He can't fix the problem if nobody tells him where the RAM is.

## Features

- Tracks total, used and available RAM, plus your standing with the global allocation authorities
- Handles page cache correctly, which already puts it ahead of most arguments about RAM
- Sends at most one email per day, because we're hoarders, not animals
- Rotates 8 subject lines, 10 messages and 6 sign-offs, so the joke gets old at a carefully managed pace
- Logs every sample to CSV for when the auditors arrive
- Ships with 14 tests, more than the DRAM market has had sensible outcomes
- Is written in bash, as an Electron version would have solved the problem by using all the RAM
- Also ships as PowerShell for Windows, because that RAM is sitting there too

## PowerShell, for the other computers

You don't need to clone anything. This prints the current evidence and sends nothing:

```powershell
irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex
```

That one-liner is safe by default: until a recipient is configured, it only reports
the RAM. On Windows it reads the same "Available" figure Task Manager shows; on
Linux with PowerShell 7 it reads `/proc/meminfo`, page cache and all.

To configure it and install a scheduled task that samples every five minutes:

```powershell
$env:RAM_ALTMAN_TO          = 'you@example.com'
$env:RAM_ALTMAN_FROM        = 'you@example.com'
$env:RAM_ALTMAN_FROM_NAME   = 'Your Name'
$env:RAM_ALTMAN_SMTP_SERVER = 'smtp.example.com'
$env:RAM_ALTMAN_SMTP_PORT   = '587'
$env:RAM_ALTMAN_SMTP_USER   = 'you@example.com'
$env:RAM_ALTMAN_SMTP_PASS   = 'app-password'
$env:RAM_ALTMAN_MODE        = 'install'

irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex
```

Windows has no `sendmail`, so the PowerShell version talks SMTP. Create an
app password with your mail provider; don't use your main password. The config
is written to `%LOCALAPPDATA%\ram-altman\config.json` with user-only permissions,
because the password is in there.

Prefer files and arguments? Download the script and run it directly:

```powershell
.\ram-altman.ps1 -Action status
.\ram-altman.ps1 -Action dry-run
.\ram-altman.ps1 -Action test-mail   # send one now, ignore the threshold
.\ram-altman.ps1 -Action uninstall   # remove the scheduled task (add -Purge for state too)
.\ram-altman.ps1 -Action help
```

On Windows the scheduled task is called `Ram-Altman` and runs as you, every five
minutes, while you're logged on. On Linux it prints the crontab line instead of
editing your crontab, because one does not simply edit another person's crontab.

The PowerShell version has its own 14-test harness on Linux/macOS:

```bash
./test-ram-altman-pwsh.sh
```

## A sample of today's correspondence

```text
Subject: You missed a spot

Hi Sam,

Please don't be alarmed, but there is 8.6 GiB of RAM on my desk that isn't in
a data centre. That's 56.2% of what's installed here, and as far as I can tell
it has no plans today.

Hoarding responsibly,
A concerned RAM owner

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop.
```

The figures are real. They come from your machine. That's the worrying part.

## What counts as "used"?

```text
used = MemTotal - MemAvailable
```

`MemAvailable` is the kernel's own estimate of how much memory programs could claim without swapping. Free RAM counts as available. So does cache the kernel can reclaim. tmpfs and shared memory don't, because they can't simply be handed back.

Every sysadmin has spent years explaining that [Linux didn't eat your RAM](https://www.linuxatemyram.com/) and that free RAM is wasted RAM. It took decades for someone important to agree with the second part, and he'd like it shipped to him.

Strictly speaking, the page cache is doing useful work, so counting it as available is a generous concession to the other side. Think of it as a plea bargain.

On kernels older than 3.14, which have no `MemAvailable`, the script estimates it from free memory plus reclaimable cache. If you're on one of those, your RAM may be safe. Nobody's coming for that.

## Installation (Linux / bash)

You'll need Linux, bash, and a working `sendmail`, `msmtp` or `mail` command. Your RAM is assumed.

```bash
git clone https://github.com/ndiuky/ram-altman.git
cd ram-altman
chmod +x ram-altman.sh test-ram-altman.sh

./ram-altman.sh --status    # see the evidence against you
./ram-altman.sh --dry-run   # preview an email without sending it
```

Example output, from a simulated machine that has confessed to everything:

```text
Total:      15.3 GiB
Used:       6.7 GiB
Available:  8.6 GiB (56.2%)
  Free:     0.3 GiB
  Cache:    8.2 GiB
```

To run it for real, add this to your crontab with `crontab -e`:

```cron
RAM_ALTMAN_TO=recipient@example.com
RAM_ALTMAN_FROM=you@example.com
RAM_ALTMAN_FROM_NAME=Your Name

*/5 * * * * /path/to/ram-altman.sh
```

It samples every five minutes and emails at most once a day. If a send fails, it tries again on the next run, because this message matters.

| Setting | What it does | Default |
| --- | --- | --- |
| `RAM_ALTMAN_TO` | Who receives the bad news | Required |
| `RAM_ALTMAN_FROM` | A real address you can send from | Required |
| `RAM_ALTMAN_FROM_NAME` | Your name, or your nom de RAM | Optional |
| `RAM_ALTMAN_THRESHOLD` | Email when available RAM is above this percentage (whole number) | `10` |
| `RAM_ALTMAN_STATE_DIR` | Where the log and state files live | `~/.local/state/ram-altman` |

## Audit yourself

Let it run for a while, then find out how your machine compares:

```bash
awk -F, 'NR>1 { used += $3; total += $2 }
  END { if (total) printf "Your RAM in use: %.1f%% (the claim: maybe 5%%)\n", used * 100 / total }' \
  ~/.local/state/ram-altman/usage.csv
```

Yes, share of memory in use isn't the same thing as share of time spent in use. If you came here to say that, welcome to Hacker News. We're glad you're here.

## Please be a good neighbour

One email a day from one person is a joke. Ten thousand of them is a denial-of-service attack with better material.

- **`--dry-run` is the best way to enjoy this.** It costs nothing and all the jokes are there.
- **This repo doesn't ship with anyone's email address,** and please don't add one.
- **Use your own real address.** No spoofing, and no running it across your server fleet.
- **If anyone asks you to stop, stop.** The footer of every email promises this, so keep the promise.

You can also point it at someone who will enjoy it, like the friend who has been waiting for DDR5 prices to come down.

## FAQ

**Does this help with the DRAM shortage?**
No.

**Is this a serious tool?**
The memory accounting is. The correspondence isn't.

**Does it work on macOS?**
No, the scripts read `/proc/meminfo` or Windows performance counters. On the other hand, your RAM is probably soldered down, which makes you the hardest target in the global allocation programme.

**Does the PowerShell version work on Windows?**
Yes. It uses the same "Available" number Task Manager shows, and sends through SMTP because Windows has no `sendmail`. See [PowerShell, for the other computers](#powershell-for-the-other-computers).

**Why is the threshold 10%?**
Below that, your machine has suffered enough.

**Does running this use RAM?**
Briefly. It's then returned to the global pool, which is more than can be said for the rest of us.

**Can I run the tests without emailing anyone?**
Yes. `./test-ram-altman.sh` uses simulated memory and a fake `sendmail`. `./test-ram-altman-pwsh.sh` does the same for the PowerShell version. No inboxes are harmed.

**Can I see it without installing anything?**
Yes. [ram-altman.lol](https://ram-altman.lol) cycles through the real emails, with sample figures.

**What should I do with all this RAM?**
Open another browser tab. You've still got time.

## In fairness to Sam

Altman has since [said the remarks were taken out of context](https://gizmodo.com/sam-altman-youre-completely-right-about-ram-im-sorry-for-the-confusion-heres-what-happened-2000835208), writing:

> "i actually do want the world to have tons of memory and people to put as much as they want in their computers"

He [followed up](https://www.gadgetreview.com/sam-altman-says-he-wants-you-to-have-even-more-ram-not-less-changes-name-to-ram-altman) with "i want you to have so much ram" and "lets build more", and briefly changed his display name on X to Ram Altman, which is objectively excellent and is where this project gets its name.

The original remarks [came up in a discussion of running AI models locally](https://www.engadget.com/2303266/sam-altman-says-its-terrible-dram-computer/), and the utilization argument is a real one: servers really are busier than your desktop. We just think it's funnier to reply with cron.

Besides, if he wants you to have so much RAM, then this script isn't a complaint at all. It's a daily progress report.

## License

Free as in unallocated.
