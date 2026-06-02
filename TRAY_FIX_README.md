# VTT Tray Icon Double-Click Issue - Fix Applied

## Problem Description
The tray icon was visible in the system tray, but double-clicking it did not open the dashboard UI. This issue appeared after starting screen recording software.

## Root Causes Identified

### 1. **Insufficient Window Activation**
The original code only called `BringToFront()` when the form already existed, which may not be sufficient when:
- The window is minimized
- The window is hidden behind other windows
- Screen recording software is capturing focus
- Windows focus-stealing prevention is active

### 2. **Lack of Logging**
There was no way to diagnose what was happening when the double-click event fired, making it impossible to determine if:
- The event was being triggered
- The function was being called
- An error was occurring silently

### 3. **Missing Error Handling**
No try-catch blocks meant that any exceptions would fail silently without notification.

## Changes Made

### 1. Enhanced Window Activation (vtt-tray.ps1)
```powershell
# Before:
$script:mainForm.BringToFront(); return

# After:
$script:mainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
$script:mainForm.Activate()
$script:mainForm.BringToFront()
$script:mainForm.TopMost = $true
$script:mainForm.TopMost = $false
```

This ensures:
- Window is restored from minimized state
- Window is activated (receives focus)
- Window is brought to front
- TopMost trick forces it above other windows temporarily

### 2. Comprehensive Logging
Added logging throughout the tray script:
- Tray startup and initialization
- Single-click and double-click events
- Dashboard creation and showing
- Form shown and closed events
- All errors with stack traces

Log location: `%TEMP%\vtt\tray.log`

### 3. Error Handling
Added try-catch blocks:
- Around the entire `Show-Dashboard` function
- Around the double-click event handler
- Error messages shown to user via MessageBox
- All errors logged to tray.log

### 4. New Management Commands (vtt.ps1)
```powershell
vtt tray-stop  # Stop the tray icon process
vtt logs       # Now includes tray logs
```

## How to Test the Fix

### Step 1: Stop the Current Tray
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Idan_Shemtov\vtt\vtt.ps1 tray-stop
```

### Step 2: Start the Tray Again
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Idan_Shemtov\vtt\vtt.ps1 tray
```

### Step 3: Test Double-Click
1. Find the VTT tray icon in the system tray (notification area)
2. Double-click it
3. The dashboard should open

### Step 4: Check Logs if It Still Doesn't Work
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Idan_Shemtov\vtt\vtt.ps1 logs
```

Look at the "=== Tray Log ===" section to see:
- If the double-click event is firing
- If Show-Dashboard is being called
- If there are any errors

## Alternative: Use the Context Menu
If double-clicking still doesn't work, you can:
1. Right-click the tray icon
2. Select "Open Dashboard" from the menu

This uses the same `Show-Dashboard` function, so it should work the same way.

## Possible Screen Recording Software Interference

Some screen recording software (like OBS, Camtasia, etc.) can:
- Intercept mouse events
- Prevent window activation
- Block focus changes

If the issue persists only when screen recording:
1. Check your recording software's settings for "capture mouse clicks" or similar
2. Try running the recording software as a normal user (not administrator)
3. Try excluding the VTT tray process from recording
4. Use the right-click context menu instead of double-clicking

## Technical Details

### Why TopMost Trick Works
```powershell
$script:mainForm.TopMost = $true
$script:mainForm.TopMost = $false
```

This temporarily makes the window "always on top", which forces Windows to:
1. Bring it to the absolute front
2. Give it focus
3. Then we immediately disable TopMost so it behaves normally

This is more aggressive than just `BringToFront()` and works better when other applications are trying to maintain focus.

### Single-Instance Protection
The tray uses a named mutex (`Local\VTT-Tray-v1`) to ensure only one instance runs. If you try to start a second tray, it will exit silently. This is why `tray-stop` is needed before restarting.

## Files Modified
1. `vtt-tray.ps1` - Added logging, error handling, improved window activation
2. `vtt.ps1` - Added tray-stop command and tray log viewing

## Next Steps
If the issue persists after these changes, the tray.log file will contain detailed information about what's happening, which can be used for further debugging.
