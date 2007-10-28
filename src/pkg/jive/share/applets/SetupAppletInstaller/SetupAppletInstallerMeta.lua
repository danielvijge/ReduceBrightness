
--[[
=head1 NAME

applets.SetupAppletInstaller.SetupAppletInstallerMeta - SetupAppletInstaller meta-info

=head1 DESCRIPTION

See L<applets.SetupAppletInstaller.SetupAppletInstallerApplet>.

=head1 FUNCTIONS

See L<jive.AppletMeta> for a description of standard applet meta functions.

=cut
--]]


local oo            = require("loop.simple")

local jiveMain      = jiveMain
local AppletMeta    = require("jive.AppletMeta")
local jul           = require("jive.utils.log")

local appletManager = appletManager


module(...)
oo.class(_M, AppletMeta)


function jiveVersion(self)
	return 1, 1
end

function defaultSettings(self)
	return {}
end

function registerApplet(self)
	local remoteSettings = jiveMain:subMenu(self:string("SETTINGS")):subMenu(self:string("REMOTE_SETTINGS"))
	local advancedSettings = remoteSettings:subMenu(self:string("ADVANCED_SETTINGS"), 1000)

	advancedSettings:addItem(self:menuItem("APPLET_INSTALLER", function(applet, ...) applet:menu(...) end))
end

