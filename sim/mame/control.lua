-- SPDX-License-Identifier: CERN-OHL-S-2.0
-- Copyright 2026 Romain Dolbeau
-- Source location: https://github.com/MelkhiorVintageComputing/RD68031
--
-- MAME autoboot script for sim/mame/drive.py: once the file `stop` appears in
-- the working directory, print the emulated time and leave MAME cleanly (so
-- that it prints its average speed). Polled at every periodic callback.
local n = 0
emu.register_periodic(function()
  n = n + 1
  if n % 16 ~= 0 then return end
  local f = io.open("stop", "r")
  if f then
    f:close()
    os.remove("stop")
    print(string.format("emulated time: %.3f s", manager.machine.time:as_double()))
    manager.machine:exit()
  end
end)
