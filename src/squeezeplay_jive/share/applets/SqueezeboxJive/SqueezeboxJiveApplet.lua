
-- stuff we use
local ipairs, pcall, tostring = ipairs, pcall, tostring

local oo                     = require("loop.simple")
local string                 = require("string")
local math                   = require("math")
local os                     = require("os")
local io                     = require("io")

local jiveBSP                = require("jiveBSP")
local Watchdog               = require("jiveWatchdog")
local Wireless               = require("jive.net.Wireless")
local LocalPlayer            = require("jive.slim.LocalPlayer")

local Applet                 = require("jive.Applet")
local Sample                 = require("squeezeplay.sample")
local Checkbox               = require("jive.ui.Checkbox")
local Choice                 = require("jive.ui.Choice")
local Font                   = require("jive.ui.Font")
local Framework              = require("jive.ui.Framework")
local Group                  = require("jive.ui.Group")
local Icon                   = require("jive.ui.Icon")
local Label                  = require("jive.ui.Label")
local Popup                  = require("jive.ui.Popup")
local RadioButton            = require("jive.ui.RadioButton")
local RadioGroup             = require("jive.ui.RadioGroup")
local SimpleMenu             = require("jive.ui.SimpleMenu")
local Slider                 = require("jive.ui.Slider")
local Surface                = require("jive.ui.Surface")
local Textarea               = require("jive.ui.Textarea")
local Task                   = require("jive.ui.Task")
local Tile                   = require("jive.ui.Tile")
local Timer                  = require("jive.ui.Timer")
local Checkbox               = require("jive.ui.Checkbox")
local Window                 = require("jive.ui.Window")

local debug                  = require("jive.utils.debug")
local log                    = require("jive.utils.log").logger("applets.setup")

local jnt                    = jnt
local iconbar                = iconbar
local appletManager          = appletManager

local LAYER_FRAME            = jive.ui.LAYER_FRAME
local LAYER_CONTENT_ON_STAGE = jive.ui.LAYER_CONTENT_ON_STAGE

local LAYOUT_NORTH           = jive.ui.LAYOUT_NORTH
local LAYOUT_EAST            = jive.ui.LAYOUT_EAST
local LAYOUT_SOUTH           = jive.ui.LAYOUT_SOUTH
local LAYOUT_WEST            = jive.ui.LAYOUT_WEST
local LAYOUT_CENTER          = jive.ui.LAYOUT_CENTER
local LAYOUT_NONE            = jive.ui.LAYOUT_NONE

local SW_AC_POWER            = 0
local SW_PHONE_DETECT        = 1

local squeezeboxjiveTitleStyle = 'settingstitle'
module(..., Framework.constants)
oo.class(_M, Applet)


-- disable battery low test, useful for debugging
local CHECK_BATTERY_LOW      = true


function init(self)
	local uuid, mac

	-- read device uuid
	local f = io.popen("/usr/sbin/fw_printenv")
	if f then
		local printenv = f:read("*all")
		f:close()

		uuid = string.match(printenv, "serial#=(%x+)")
	end
	
	-- read device mac
	local f = io.popen("/sbin/ifconfig eth0")
	if f then
		local ifconfig = f:read("*all")
		f:close()

		mac = string.match(ifconfig, "HWaddr%s(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	end

	log:info("uuid=", uuid)
	log:info("mac=", mac)

	if not uuid or string.match(mac, "^00:40:20") then
		local popup = Popup("errorWindow", self:string("INVALID_MAC_TITLE"))

		popup:setAllowScreensaver(false)
		popup:setAlwaysOnTop(true)
		popup:setAutoHide(false)

		local text = Textarea("textarea", self:string("INVALID_MAC_TEXT"))
		local menu = SimpleMenu("menu", {
			{
				text = self:string("INVALID_MAC_CONTINUE"),
				sound = "WINDOWHIDE",
				callback = function()
						   popup:hide()
					   end
			},
		})

		popup:addWidget(text)
		popup:addWidget(menu)
		popup:show()
	end


	jnt:setUUID(uuid, mac)

	-- watchdog timer
	self.watchdog = Watchdog:open()
	if self.watchdog then
		-- allow 30 seconds to boot
		self.watchdog:setTimeout(30)
		local timer = Timer(2000, -- 2 seconds
			function()
				-- 10 second when running
				--if not self.watchdogRunning then
				--	self.watchdog:setTimeout(10)
				--	self.watchdogRunning = true
				--end
				self.watchdog:keepAlive()
			end)
		timer:start()
	else
		log:warn("Watchdog timer is disabled")
	end

	-- sync clock to hw clock every 10 minutes
	clockSyncTimer = Timer(600000, -- 10 minutes
		function()
			local systemTime = os.date()
			log:info('syncing system clock to hw clock: ', systemTime)
			os.execute("hwclock -s")
			systemTime = os.date()
			log:info('system clock now synced to hw clock: ', systemTime)
		end)
	clockSyncTimer:start()

	-- register wakeup function
	Framework:registerWakeup(function()
					 wakeup(self)
				 end)

	-- wireless
	self.wireless = Wireless(jnt, "eth0")

	-- register network active function
	jnt:registerNetworkActive(function(active)
		self:_wlanPowerSave(active)
	end)

	jnt:registerCpuActive(function(active)
		self:_cpuPowerOverride(active)
	end)

	iconbar.iconWireless:addTimer(5000,  -- every 5 seconds
				      function() 
					      self:update()
				      end)

	Framework:addListener(EVENT_SWITCH,
			      function(event)
				      local type = event:getType()
				      local sw,val = event:getSwitch()

				      if sw == SW_AC_POWER then
					      log:info("acpower=", val)

					      self.acpower = (val == 0)
					      self:update()

					      if self.acpower then
						      self:setPowerState("dimmed")
						      iconbar.iconBattery:playSound("DOCKING")
					      else
						      self:setPowerState("active")
					      end

				      elseif sw == SW_PHONE_DETECT then
				              headphoneJack(self, val)
				      end

				      return EVENT_CONSUME
			      end)

	-- power management (evaluate every minute)
	self.lastMotion = Framework:getTicks()
	self.lastPress = self.lastMotion
	self.powerTimer = Timer(10000, function()
		sleep(self)
	end)

	Framework:addListener(EVENT_MOTION,
			      function(event) 
				      if not self.acpower then
					      wakeup(self, 'motion')
				      end
				      return EVENT_UNUSED
			      end)

	Framework:addListener(EVENT_SCROLL,
			      function(event) 
				      wakeup(self, 'press')
				      return EVENT_UNUSED
			      end)

	Framework:addListener(EVENT_KEY_PRESS,
			      function(event) 
				      local keycode = event:getKeycode()

				      -- key lock
				      if keycode == (KEY_ADD | KEY_PLAY) then
					      Framework:playSound("WINDOWSHOW")
					      lockScreen(self)
					      return EVENT_CONSUME
				      end

				      wakeup(self, 'press')
				      return EVENT_UNUSED
			      end)

	Framework:addListener(EVENT_KEY_HOLD,
		function(event) 
			local keycode = event:getKeycode()

			-- press-hold home is for power down
			if keycode == KEY_HOME then
				settingsPowerOff(self)
				return EVENT_CONSUME
			end
			return EVENT_UNUSED
		end)


	-- brightness
	self.lcdLevel = jiveBSP.ioctl(12) / 2048
	self.keyLevel = jiveBSP.ioctl(14) / 512

	-- ac or battery
	self.acpower = (jiveBSP.ioctl(23) == 0)
	if self.acpower then
		self:setPowerState("dimmed")
	else
		self:setPowerState("active")
	end

	-- headphone or speaker
	local headphoneInserted = jiveBSP.ioctl(18)
	self:headphoneJack(headphoneInserted)

	-- set initial state
	self:update()

	-- find out when we connect to player
	jnt:subscribe(self)

	return self
end


function notify_playerCurrent(self, player)
	-- track changes to the remote player selection for headphone jack
	if player and not player:isLocal() then
		self.remotePlayer = player
	end

	-- if not passed a player, or if player hasn't change, exit
	if not player or not player:isConnected() then
		return
	end

	if self.player == player then
		return
	end

	self.player = player

	local sink = function(chunk, err)
			     if err then
				     log:warn(err)
				     return
			     end
				log:debug('Date being synched from player to controller: ', chunk.data.date)
                             self:setDate(chunk.data.date)
 		     end

 
	-- setup a once/hour
        player:subscribe(
                         '/slim/datestatus/' .. self.player:getId(),
                         sink,
                         self.player:getId(),
                         { 'date', 'subscribe:3600' }
	)

end

function notify_playerDelete(self, player)
	if self.player ~= player then
		return
	end

	log:warn('unsubscribing from datestatus/', self.player:getId())
	self.player:unsubscribe('/slim/datestatus/' .. self.player:getId())
	self.player = false

end

function setDate(self, date)
	-- matches date format 2007-09-08T20:40:42+00:00
	local CCYY, MM, DD, hh, mm, ss, TZ = string.match(date, "(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)([-+]%d%d:%d%d)")

	log:info("CCYY=", CCYY, " MM=", MM, " DD=", DD, " hh=", hh, " mm=", mm, " ss=", ss, " TZ=", TZ)

	-- set system date
	os.execute("date " .. MM..DD..hh..mm..CCYY.."."..ss)

	-- set RTC to system time
	os.execute("hwclock -w")

	iconbar:update()
end


function update(self)
	-- ac power / battery
	if self.acpower then
		if self.batteryPopup then
			self:batteryLowHide()
		end

		local nCHRG = jiveBSP.ioctl(25)
		if nCHRG == 0 then
			iconbar:setBattery("CHARGING")
		else
			iconbar:setBattery("AC")
		end
	else
		local bat = jiveBSP.ioctl(17)
		if CHECK_BATTERY_LOW and bat < 807 then
			self:batteryLowShow()
		elseif bat < 820 then
			iconbar:setBattery("0")
		elseif bat < 834 then
			iconbar:setBattery("1")
		elseif bat < 855 then
			iconbar:setBattery("2")
		elseif bat < 875 then
			iconbar:setBattery("3")
		else
			iconbar:setBattery("4")
		end
	end

	-- wireless strength
	local quality = self.wireless:getLinkQuality()
	iconbar:setWirelessSignal(quality ~= nil and quality or "ERROR")
end


function headphoneJack(self, inserted)
	-- switch between headphone and speaker
	if inserted == 1 then
		os.execute("amixer -q sset Headphone 92%")
		os.execute("amixer -q sset Endpoint Headphone")
		Sample:setEffectAttenuation(Sample.MAXVOLUME / 4)
	else
		os.execute("amixer -q sset Endpoint Speaker")
		Sample:setEffectAttenuation(Sample.MAXVOLUME)
	end

	-- automatically select internal player
	if inserted == 1 then
		local localPlayer

		if appletManager:hasService("iteratePlayers") then
			for _, player in appletManager:callService("iteratePlayers") do
				if player and player:isLocal() then
					localPlayer = player
					break
				end
			end
		end

		if localPlayer then

			local currentPlayer = appletManager:callService("getCurrentPlayer")
			if currentPlayer ~= localPlayer then
				self.remotePlayer = currentPlayer
				appletManager:callService("setCurrentPlayer", localPlayer)
			end
		end
	else
		-- switch back to remote player
		if self.remotePlayer then
			appletManager:callService("setCurrentPlayer", self.remotePlayer)
			self.remotePlayer = nil
		end
	end
end


function _brightness(self, lcdLevel, keyLevel)
	local settings = self:getSettings()

	if lcdLevel ~= nil then
		-- don't update the screen when the lcd is off
		Framework:setUpdateScreen(lcdLevel ~= 0)

		self.lcdLevel = lcdLevel
		jiveBSP.ioctl(11, lcdLevel * 2048)
	end

	if keyLevel ~= nil then
		self.keyLevel = keyLevel
		jiveBSP.ioctl(13, keyLevel * 512)
	end
end


function _setBrightness(self, fade, lcdLevel, keyLevel)
	-- stop existing fade
	if self.fadeTimer then
		self.fadeTimer:stop()
		self.fadeTimer = nil
	end

	if not fade then
		_brightness(self, lcdLevel, keyLevel)
		return
	end

	-- FIXME implement smooth fade in kernel using pwm interrupts
	local steps = 30
	local lcdVal = self.lcdLevel
	local lcdInc = (lcdVal - lcdLevel) / steps
	local keyVal = self.keyLevel
	local keyInc = (keyVal - keyLevel) / steps

	if lcdVal == lcdLevel and keyVal == keyLevel then
		return
	end

	self.fadeTimer = Timer(20, function()
					   if steps == 0 then
						   if self.fadeTimer then
							   self.fadeTimer:stop()
							   self.fadeTimer = nil
						   end

						   -- ensure we hit the set value
						   _brightness(self, lcdLevel, keyLevel)
						   return
					   end

					   steps = steps - 1
					   lcdVal = lcdVal - lcdInc
					   keyVal = keyVal - keyInc
					   _brightness(self, math.ceil(lcdVal), math.ceil(keyVal))
				   end)
	self.fadeTimer:start()
end

function getBrightness(self)
	local settings = self:getSettings()
	return settings.brightness
end

function setBrightness(self, level)
	local settings = self:getSettings()

	if level then
		settings.brightness = level
	end

	local lcdLevel = level or settings.brightness
	local keyLevel = 0

	if self.powerState == "active" then
		keyLevel = level or settings.brightness
	end

	_setBrightness(self, false, lcdLevel, keyLevel)
end

function settingsBrightnessShow(self, menuItem)
	local window = Window("window", menuItem.text, squeezeboxjiveTitleStyle)

	local level = jiveBSP.ioctl(12) / 2047

	local slider = Slider("slider", 1, 32, level,
			      function(slider, value, done)
				      self:setBrightness(value)

				      if done then
					      window:playSound("WINDOWSHOW")
					      window:hide(Window.transitionPushLeft)
				      end
			      end)

	window:addWidget(Textarea("help", self:string("BSP_BRIGHTNESS_ADJUST_HELP")))
	window:addWidget(Group("sliderGroup", {
				       Icon("sliderMin"),
				       slider,
				       Icon("sliderMax")
			       }))

	window:addListener(EVENT_WINDOW_POP,
		function()
			self:storeSettings()
		end
	)

	window:show()
	return window
end


function setBacklightTimeout(self, timeout)
	local settings = self:getSettings()
	settings.dimmedTimeout = timeout

	self:setPowerState(self.powerState)	
end


function settingsBacklightTimerShow(self, menuItem)
	local window = Window("window", menuItem.text, squeezeboxjiveTitleStyle)

	local settings = self:getSettings()
	local timeout = settings.dimmedTimeout

	local group = RadioGroup()
	local menu = SimpleMenu("menu", {
					{
						text = self:string("BSP_TIMER_10_SEC"),
						icon = RadioButton("radio", group, function() self:setBacklightTimeout(10000) end, timeout == 10000),
					},
					{
						text = self:string("BSP_TIMER_20_SEC"),
						icon = RadioButton("radio", group, function() self:setBacklightTimeout(20000) end, timeout == 20000),
					},
					{
						text = self:string("BSP_TIMER_30_SEC"),
						icon = RadioButton("radio", group, function() self:setBacklightTimeout(30000) end, timeout == 30000),
					},
					{
						text = self:string("BSP_TIMER_1_MIN"),
						icon = RadioButton("radio", group, function() self:setBacklightTimeout(60000) end, timeout == 60000),
					},
					{
						text = self:string("BSP_TIMER_NEVER"),
						icon = RadioButton("radio", group, function() self:setBacklightTimeout(0) end, timeout == 0),
					},
					{
						text = self:string("DIM_WHEN_CHARGING"),
						icon = Checkbox("checkbox",
								function(obj, isSelected)
									settings.dimmedAC = isSelected
								end,
								settings.dimmedAC)
					}
				})

	window:addWidget(menu)

	window:addListener(EVENT_WINDOW_POP,
		function()
			self:storeSettings()
		end
	)

	window:show()
	return window
end


-- called to wake up jive
function wakeup(self, action)
	if action == 'motion' then
		self.lastMotion = Framework:getTicks()
	end
	if action == 'press' then
		self.lastPress = Framework:getTicks()
	end

	if self.lockedPopup then
		-- we're locked do nothing
		return
	end

	if self.powerState == "active" then
		self.powerTimer:restart()
	else
		self:setPowerState("active")
	end
end


-- called to sleep jive
function sleep(self)
	local settings = self:getSettings()

	local now = Framework:getTicks()
	local deltaMotion = now - self.lastMotion
	local deltaPress = now - self.lastPress

	local motionTimeout = 0
	local pressTimeout = 0
	local nextState = false

	-- don't sleep or suspend with a popup visible
	-- e.g. Bug 6641 during a firmware upgrade
	local topWindow = Framework.windowStack[1]
	if not topWindow:canActivatePowersave()then
		pressTimeout = now
		nextState = "active"

	elseif self.powerState == "active" then
		motionTimeout = settings.dimmedTimeout
		pressTimeout = settings.dimmedTimeout
		nextState = "dimmed"

	elseif self.powerState == "locked" then
		motionTimeout = settings.dimmedTimeout
		pressTimeout = settings.dimmedTimeout
		nextState = "sleep"

	elseif self.powerState == "dimmed" then
		motionTimeout = settings.dimmedTimeout + settings.sleepTimeout
		pressTimeout = settings.dimmedTimeout + settings.sleepTimeout
		nextState = "sleep"

	elseif self.powerState == "sleep" then
		-- motion timeout to enter sleep is shorter than the press
		-- timeout, so accidental motion does not prevent suspend
		motionTimeout = settings.dimmedTimeout + settings.sleepTimeout

		-- suspend timeout varies depending on playmode
		local player = appletManager:callService("getCurrentPlayer")	
		if player and player:getPlayMode() == "play" then
			pressTimeout = settings.sleepTimeout + settings.suspendWhenPlayingTimeout
		else
			pressTimeout = settings.sleepTimeout + settings.suspendWhenStoppedTimeout
		end
		nextState = "suspend"

	elseif self.powerState == "suspend" then
		-- we can't go to sleep anymore
	end

	log:debug("powerState=", self.powerState, " nextState=", nextState, " motion=", (motionTimeout - deltaMotion), " press=", (pressTimeout - deltaPress))

	if nextState and (deltaMotion >= motionTimeout) and (deltaPress >= pressTimeout) then
		self:setPowerState(nextState)
	end
end


-- set the power state and update devices
function setPowerState(self, state, action)
	local settings = self:getSettings()

	log:info("setPowerState=", state, " acpower=", self.acpower)
	self.powerState = state

	if self.acpower then
		-- charging
		self:_cpuPowerSave(true)

		if self.audioVolume ~= nil then
			log:info("Restore effect volume ", self.audioVolume)
			Sample:setEffectVolume(self.audioVolume)
			self.audioVolume = nil
		end

		if state == "active" then
			self:setBrightness()
			
		elseif state == "dimmed" then
			if settings.dimmedAC then
				self:_setBrightness(true, 8, 0)
			else
				self:setBrightness()
			end

		elseif state == "sleep" then
			if settings.dimmedAC then
				self:_setBrightness(true, 0, 0)
			else
				self:setBrightness()
			end
		end

	else
		-- battery

		if state == "active" then
			self:_cpuPowerSave(true)
			self:setBrightness()

			if self.audioVolume ~= nil then
				log:info("Restore effect volume ", self.audioVolume)
				Sample:setEffectVolume(self.audioVolume)
				self.audioVolume = nil
			end

		elseif state == "locked" then
			self:_cpuPowerSave(true)
			self:setBrightness()

			if self.audioVolume ~= nil then
				log:info("Restore effect volume ", self.audioVolume)
				Sample:setEffectVolume(self.audioVolume)
				self.audioVolume = nil
			end

			self.lockedTimer:restart()

		elseif state == "dimmed" then
			self:_cpuPowerSave(true)
			if settings.dimmedTimeout > 0 then
				self:_setBrightness(true, 8, 0)
			end

		else
			self:_setBrightness(true, 0, 0)
			self:_cpuPowerSave(false)

			if not self.audioVolume then
				self.audioVolume = Sample:getEffectVolume()
				log:info("Store effect volume ", self.audioVolume)
				Sample:setEffectVolume(0)
			end

			if state == "suspend" then
				if settings.suspendEnabled then
					self:_suspend()
				end
			end
		end
	end

	-- update wlan power save mode
	self:_wlanPowerSave()

	self.powerTimer:restart()
end


function lockScreen(self)
	-- lock
	local popup = Popup("popupIcon")

	popup:setAllowScreensaver(false)
	popup:setAlwaysOnTop(true)
	popup:setAutoHide(false)

	-- FIXME change icon and text
	popup:addWidget(Icon("iconLocked"))
	popup:addWidget(Label("text", self:string("BSP_SCREEN_LOCKED")))
	popup:addWidget(Textarea("lockedHelp", self:string("BSP_SCREEN_LOCKED_HELP")))

	popup:show()

	self.lockedPopup = popup
	self.lockedTimer = Timer(5000,
				 function()
					 self:_setBrightness(true, 0, 0)
					 self:_cpuPowerSave(false)
				 end,
				 true)

	self:setPowerState("locked")

	self.lockedListener = 
		Framework:addListener(EVENT_KEY_DOWN | EVENT_KEY_PRESS,
				      function(event)
					      if event:getType() == EVENT_KEY_PRESS and event:getKeycode() == (KEY_ADD | KEY_PLAY) then
						      popup:playSound("WINDOWHIDE")
						      unlockScreen(self)
						      return EVENT_CONSUME
					      end

					      self:setPowerState("locked")
					      return EVENT_CONSUME
				      end,
				      true)
end


function unlockScreen(self)
	if self.lockedPopup then
		-- unlock
		Framework:removeListener(self.lockedListener)
		self.lockedTimer:stop()
		self.lockedPopup:hide()

		self.lockedPopup = nil
		self.lockedTimer = nil
		self.lockedListener = nil
	end
end


function batteryLowShow(self)
	if self.batteryPopup then
		return
	end

	log:info("batteryLowShow")

	local popup = Popup("popupIcon")

	popup:addWidget(Icon("iconBatteryLow"))
	popup:addWidget(Label("text", self:string("BATTERY_LOW")))

	-- make sure this popup remains on screen
	popup:setAllowScreensaver(false)
	popup:setAlwaysOnTop(true)
	popup:setAutoHide(false)

	self.batteryPopup = popup

	popup:addTimer(30000,
		       function()
			       self:_powerOff()
		       end,
		       true)

	-- consume all key and scroll events
	self.batteryListener
		= Framework:addListener(EVENT_ALL_INPUT,
					function(event)
						Framework.wakeup()

						-- allow power off
						if event:getType() == EVENT_KEY_HOLD and event:getKeycode() == KEY_HOME then
							self:settingsPowerOff()
						end
						return EVENT_CONSUME
					end,
					true)

	-- make sure the display is on
	self:setBrightness()

	popup:show()
end


function batteryLowHide(self)
	log:info("batteryLowHide")

	Framework:removeListener(self.batteryListener)
	self.batteryPopup:hide()

	self.batteryPopup = nil
	self.batteryListener = nil
end


function settingsPowerDown(self, menuItem)
        log:debug("powerDown menu")
	-- add window
	local window = Window("window", menuItem.text, 'settingstitle')
	window:addWidget(Textarea("help", self:string("POWER_DOWN_HELP")))

	local menu = SimpleMenu("menu")
	window:addWidget(menu)


	local items = {
		{ 
			text = self:string("POWER_DOWN_CANCEL"),
			sound = "WINDOWHIDE",
			callback = function() window:hide() end
		},
		{ 
			text = self:string("POWER_DOWN"),
			sound = "SELECT",
			callback = function() settingsPowerOff(self) end
		},	
		{ 
			text = self:string("POWER_DOWN_SLEEP"),
			sound = "SELECT",
			callback = function() settingsSleep(self) end
		}
	}
	menu:setItems(items)

	window:show()
        return window
end

function settingsSleep(self)
	-- disconnect from SqueezeCenter
	appletManager:callService("disconnectPlayer")

	self.popup = Popup("popupIcon")

	self.popup:addWidget(Icon("iconConnecting"))
	self.popup:addWidget(Label("text", self:string("SLEEPING")))

	-- make sure this popup remains on screen
	self.popup:setAllowScreensaver(false)
	self.popup:setAlwaysOnTop(true)
	self.popup:setAutoHide(false)

	self.popup:addTimer(10000, 
		function()
			self:_goToSleep()
		end,
		true
	)

	self.popup:show()

	self.popup:playSound("SHUTDOWN")
end


function settingsPowerOff(self)
	-- disconnect from SqueezeCenter
	appletManager:callService("disconnectPlayer")

	local popup = Popup("popupIcon")

	popup:addWidget(Icon("iconPower"))
	popup:addWidget(Label("text", self:string("GOODBYE")))

	-- make sure this popup remains on screen
	popup:setAllowScreensaver(false)
	popup:setAlwaysOnTop(true)
	popup:setAutoHide(false)

	-- we're shutting down, so prohibit any key presses or holds
	Framework:addListener(EVENT_ALL_INPUT,
			      function () 
				      return EVENT_CONSUME
			      end,
			      true)

	popup:addTimer(4000, 
		function()
			self:_powerOff()
		end,
		true
	)

	popup:show()

	popup:playSound("SHUTDOWN")
end


function settingsTestSuspend(self, menuItem)
	local window = Window("window", menuItem.text, squeezeboxjiveTitleStyle)

	local settings = self:getSettings()

	local sleepOptions = { 10, 30, 60, 120 }
	local sleepIndex
	for i, v in ipairs(sleepOptions) do
		if v == (settings.sleepTimeout / 1000) then
			sleepIndex = i
			break
		end
	end

	local suspendOptions = { 10, 30, 60, 600, 1200, 2400, 3600 }
	local suspendIndex
	for i, v in ipairs(suspendOptions) do
		if v == (settings.suspendWhenPlayingTimeout / 1000) then
			suspendIndex = i
			break
		end
	end

	local menu = SimpleMenu("menu", {
		{ 
			text = "Sleep Timeout", 
			icon = Choice(
				      "choice", 
				      sleepOptions,
				      function(obj, selectedIndex)
					      settings.sleepTimeout = sleepOptions[selectedIndex] * 1000
					      log:debug("sleepTimeout=", settings.sleepTimeout)
				      end,
				      sleepIndex
			      )
		},
		{
			text = "Suspend Timeout", 
			icon = Choice(
				      "choice", 
				      suspendOptions,
				      function(obj, selectedIndex)
					      settings.suspendWhenPlayingTimeout = suspendOptions[selectedIndex] * 1000
					      settings.suspendWhenStoppedTimeout = (suspendOptions[selectedIndex] * 1000) / 2
					      log:debug("suspendWhenPlayingTimeout=", settings.suspendWhenPlayingTimeout)
				      end,
				      suspendIndex
			      )
		},
		{
			text = "Suspend Enabled", 
			icon = Checkbox(
				      "checkbox", 
				      function(obj, isSelected)
					      settings.suspendEnabled = isSelected
					      log:info("suspendEnabled=", settings.suspendEnabled)
				      end,
				      settings.suspendEnabled
			      )
		},
		{
			text = "Suspend Wake", 
			icon = Checkbox(
				      "checkbox", 
				      function(obj, isSelected)
					      settings.suspendWake = isSelected and 30 or nil
					      log:info("suspendWake=", settings.suspendWake)
				      end,
				      settings.suspendWake ~= nil
			      )
		},
		{
			text = self:string("WLAN_POWER_SAVE"), 
			icon = Checkbox(
				      "checkbox", 
				      function(obj, isSelected)
					      settings.wlanPSEnabled = isSelected
					      log:info("wlanPSEnabled=", settings.wlanPSEnabled)
					      self:_wlanPowerSave()
				      end,
				      settings.wlanPSEnabled
			      )
		},
	})

	window:addWidget(Textarea("help", self:string("POWER_MANAGEMENT_SETTINGS_HELP")))
	window:addWidget(menu)

	window:addListener(EVENT_WINDOW_POP,
		function()
			self:storeSettings()
		end
	)

	window:show()
	return window
end


function _cpuPowerSave(self, active)
	self.cpuActive = active

	self:_setCPUSpeed(self.cpuActive or self.cpuOverride)
end


function _cpuPowerOverride(self, active)
	self.cpuOverride = active

	self:_setCPUSpeed(self.cpuActive or self.cpuOverride)
end


function _setCPUSpeed(self, fast)
	local filename = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed"

	-- 200MHZ or 50MHz
	local speed = fast and 200000 or 50000

	log:info("Set CPU speed ", speed)
	local fh, err = io.open(filename, "w")
	if err then
		log:warn("Can't write to  ", filename)
		return
	end

	fh:write(speed)
	fh:close()
end


function _wlanPowerSave(self, active)
	if active ~= nil then
		-- update the network active state
		self.networkActive = active
	end

	local settings = self:getSettings()
	if not settings.wlanPSEnabled then
		self.wireless:powerSave(false)
		return
	end

	if self._wlanPowerSaveTimer == nil then
		self._wlanPowerSaveTimer =
			Timer(1000,
			      function()
				      self.wireless:powerSave(true)
			      end,
			      true)
	end

	-- disable PS mode when:
	-- 1) on ac power
	-- 2) the device is active
	-- 3) the network is active
	-- both active. when battery powered only disable PS mode when the
	-- user is actively using the device.
	if self.acpower or
		self.powerState == "active" or
		self.networkActive then

		self.wireless:powerSave(false)
		self._wlanPowerSaveTimer:stop()
	else
		self._wlanPowerSaveTimer:start()
	end
end


function _suspendTask(self)
	-- check existing network config
	local status = self.wireless:t_wpaStatus()
	local wirelessWasConnected = (status.wpa_state == 'COMPLETED')

	local zeroconf = status.ip_address and string.match(status.ip_address, "^169.254.") ~= nil

	local settings = self:getSettings()
	local wakeAfter = settings.suspendWake and settings.suspendWake or ""

	-- start timer to resume this task every second
	self.suspendPopup:addTimer(1000,
		function()
			if self.suspendTask then
				self.suspendTask:addTask()
			end
		end)

	-- disconnect from all Players/SqueezeCenters
	local connected
	repeat
		appletManager:callService("disconnectPlayer")

		connected = false
		for i,server in appletManager:callService("iterateSqueezeCenters") do
			connected = connected or server:isConnected()
			log:info("server=", server:getName(), " connected=", connected)
		end

		Task:yield(false)
	until not connected

	-- suspend
	os.execute("/etc/init.d/suspend " .. wakeAfter)

	-- wake up power state
	self:wakeup()

	while true do
		local status = self.wireless:t_wpaStatus()

		-- network connected?
		if status then
			log:info("wpa_state=", status.wpa_state, " resume ip=", status.ip_address, " zeroconf=", zeroconf)
		else
			log:info("connected=", wirelessWasConnected)
		end

		if not wirelessWasConnected and status and status.wpa_state
			or (status.wpa_state == "COMPLETED" and status.ip_address and (not string.match(status.ip_address, "^169.254.") or zeroconf)) then

			-- restart discovery
			appletManager:callService("connectPlayer")

			-- force connection to SlimServer
			if wirelessWasConnected then
				jnt:notify("networkConnected")
			end

			-- close popup
			self.suspendPopup:hide()

			-- wake up
			self:wakeup()

			self.suspendPopup = nil
			self.suspendTask = nil

			return
		end

		Task:yield(false)
	end
end


function _suspend(self)
	log:info("Suspend ...")

	-- draw popup ready for resume
	local popup = Popup("popupIcon")
	popup:setAllowScreensaver(false)
	popup:setAlwaysOnTop(true)
	popup:setAutoHide(false)
	popup:setTransparent(false)

	popup:addWidget(Icon("iconConnecting"))
	popup:addWidget(Label("text", self:string("PLEASE_WAIT")))

	-- ignore all events
	popup:addListener(EVENT_ALL_INPUT,
			   function(event)
				   return EVENT_CONSUME
			   end)

	popup:show(Window.transitionNone)
	self.suspendPopup = popup

	-- make sure the cpu is fast when we resume
	self:_cpuPowerSave(true)

	-- enable frame updates
	Framework:setUpdateScreen(true)

	-- force popup to be drawn to the framebuffer
	Framework:updateScreen()

	-- start suspend task
	self.suspendTask = Task("networkStatus", self, _suspendTask)
	self.suspendTask:addTask()
end

function _goToSleep(self)
	log:info("Sleep begin")

	self:_setBrightness(true, 0, 0)

	-- give the user 10 seconds to put the thing down, otherwise the motion detector will just bring it right back out of sleep
	self.popup:hide()
	self:setPowerState('suspend')

end

function _powerOff(self)
	log:info("Poweroff begin")

	self:_setBrightness(true, 0, 0)

	-- power off when lcd is off, or after 1 seconds
	local tries = 10
	self.powerOffTimer = Timer(100,
				   function()
					   if self.lcdLevel == 0 or tries  == 0 then
						   log:info("Poweroff on")
						   os.execute("/sbin/poweroff")
					   else
						   tries = tries - 1
					   end
				   end)
	self.powerOffTimer:start()
end


--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]
