# BeamJoy Fork

## ❗ About this fork

This repository is a **fork** of the original **BeamJoy** project.  
Its sole purpose is to propose updates and modifications that may eventually be integrated into the official repository.  
**This is not an independent version!**

---

## ✅ Always download the official version here: [Official BeamJoy Repo](https://github.com/my-name-is-samael/BeamJoy)

---

## 🚨 DISCLAIMER

> I am **not a developer**. I use **ChatGPT** to learn, fix bugs and improve the mod.  
> These fixes might solve some problems, but they could also introduce others.  
> **⚠️ Custom vehicle configs (JSON) are currently NOT properly handled in races – they are simplified and not restored correctly.**

---

## 🔧 Main Modifications

### ✅ Multiplayer Bugfixes & Improvements
- 🛠 **Fixed critical crash in `VoteRaceUI`** (race UI would crash or freeze)
- 🛠 **Fixed `deleteVehicle` button** not working correctly for owned vehicles
- 🛠 **Added debug logs** to the server-side `canSpawnOrEditVehicle()` to trace rejected spawns
- 🛠 **Fixed vehicle spawn rejection** when config was in JSON format instead of `.pc` file
- 🛠 **Handled `RaceManager`** during grid phase

### ⚠ Known Issues
- ❌ Custom vehicle configs (`.json`-based or manual parts table) **do not survive RaceManager simplification**
- ❌ These vehicles **get rejected** or **reset** to default `.pc` equivalents during races
- ⚠ This area **needs a proper design** to handle persistent vehicles with complex configurations

---

🙏 Thanks to the **BeamJoy** team for their amazing work! 🙌
