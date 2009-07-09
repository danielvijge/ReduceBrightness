
local oo            = require("loop.simple")

local AppletMeta    = require("jive.AppletMeta")

local debug         = require("jive.utils.debug")

local appletManager = appletManager
local jiveMain      = jiveMain
local jnt           = jnt

-- naughty polluting global table, but I don't want to store this
-- in the applet settings as this value does not need to be persisted


module(...)
oo.class(_M, AppletMeta)


function jiveVersion(meta)
	return 1, 1
end


function registerApplet(meta)
	jiveMain:addItem(meta:menuItem('appletSetupFirmwareUpgrade', 'advancedSettings', "UPDATE", function(applet) applet:showFirmwareUpgradeMenu() end, 115))

	meta:registerService("firmwareUpgrade")
	meta:registerService("showFirmwareUpgradeMenu")

	-- check for firmware upgrades when we connect to a new player
	-- we don't want the firmware upgrade applets always loaded so
	-- do this in the meta class
	jnt:subscribe(meta)
end


function notify_playerCurrent(meta, player)
	local server = player and player:getSlimServer()

	if not server then
		return
	end

	local url, force = server:getUpgradeUrl()

	if force then
		appletManager:callService("firmwareUpgrade", server)
	end
end


function notify_firmwareAvailable(meta, server)
	local url, force = server:getUpgradeUrl()


	if force and not url then
		log:warn("sometimes force is true but url is nil, seems like a server bug: server:", server)
	end
	if force and url then
		local player = appletManager:callService("getCurrentPlayer")

		if player and player:getSlimServer() == server then
			appletManager:callService("firmwareUpgrade", player:getSlimServer())
		end
	end
end


--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]

