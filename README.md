# ⚒️ Roblox Auto Reconnect Tools

**Automatic Detection of Disconnects, Crashes, and Freezes for Roblox on Android**  
*Open Source — Built with bash & Termux*

---

## 📖 About These Tools

These tools are designed to keep your Roblox account *online* 24/7, without worrying about disconnects or crashes.

> 💡 These tools are an optimized version of the `roblox_reconnect.sh` script.

---

## ✅ Requirements

| Requirement | Description |
|-----------|------------|
| **Android Device** | *Rooted* (with `su` access) |
| **Termux** | Version from **F-Droid** (not the Play Store) |
| **Storage** | Storage permission (`termux-setup-storage`) |
| **Internet Connection** | Stable, for downloading dependencies and accessing Roblox |

---

## 📥 Installation

Follow these steps carefully:

### 1. Install Termux from F-Droid
Download and install Termux from [F-Droid](https://f-droid.org/en/packages/com.termux/).  
> ⚠️ **Do not use the Play Store version** because it does not support all the required features.

### 2. Open Termux and Run the Command to Install Dependencies
Copy and paste the command below (one line):

```bash
pkg update -y && pkg upgrade -y && pkg install -y curl wget bash coreutils procps termux-tools tesseract tesseract-ocr-data-eng
```
> When prompted with Y/N/D, type Y (Yes) and press Enter.

### 3. Grant Storage Permissions
```
termux-setup-storage
```
> Follow the on-screen instructions to grant access to storage.

### 4. Make Sure Root Is Working
Your device must be rooted. Check with the command:

```
su
```
> If the # prompt appears, root access is successful. Type exit to return to the normal shell.

### 5. Download the Script
```
curl -o ~/roblox_reconnect.sh https://raw.githubusercontent.com/wardz25/reconnect-rblx/refs/heads/main/roblox_reconnect.sh
```
### 6. Set Execution Permissions
```
chmod +x ~/roblox_reconnect.sh
```
### 7. Run the Script for the First Time
```
bash ~/roblox_reconnect.sh
```
