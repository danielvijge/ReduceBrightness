

--[[


disconnected: no connections to any servers, and no scanning.

searching: we are not connected to a player, in this state we connect
 to all SCs and SN to discover players.

connected: we are connected to a player, only a connection to our
 SC (or SN) is maintained. udp scanning is still performed in the
 background to update the SqueezeCenter list.

probing: we are connected to a player, but we must probe all SC/SN
 update our internal state. this is used for example in the choose
 player screen.


--]]


local pairs = pairs


-- stuff we use
local oo            = require("loop.simple")
local string        = require("string")
local table         = require("jive.utils.table")

local Applet        = require("jive.Applet")

local Framework     = require("jive.ui.Framework")
local Timer         = require("jive.ui.Timer")

local SocketUdp     = require("jive.net.SocketUdp")

local Player        = require("jive.slim.Player")
local SlimServer    = require("jive.slim.SlimServer")

local debug         = require("jive.utils.debug")
local log           = require("jive.utils.log").logger("applets.setup")

local jnt           = jnt
local jiveMain      = jiveMain
local appletManager = appletManager


module(...)
oo.class(_M, Applet)


-- constants
local PORT    = 3483             -- port used to discover SqueezeCenters
local DISCOVERY_TIMEOUT = 120000 -- timeout (in milliseconds) before removing SqueezeCenters and Players

-- XXXX 60000
local DISCOVERY_PERIOD = 10000   -- discovery period



-- a ltn12 source that crafts a datagram suitable to discover SqueezeCenters
local function _slimDiscoverySource()
	return table.concat {
		"e",                                                           -- new discovery packet
		'IPAD', string.char(0x00),                                     -- request IP address of server
		'NAME', string.char(0x00),                                     -- request Name of server
		'JSON', string.char(0x00),                                     -- request JSONRPC port 
		'JVID', string.char(0x06, 0x12, 0x34, 0x56, 0x78, 0x12, 0x34), -- My ID - FIXME mac of no use!
	}
end


-- processes a udp datagram,
local function _slimDiscoverySink(self, chunk, err)
	log:debug("_processUdp()")
	
	if not chunk or not chunk.data then
		log:error("bad udp packet?")
		return
	end

	if chunk.data:sub(1,1) ~= 'E' then
		return
	end

	local name, ip, port = nil, chunk.ip, nil

	local ptr = 2
	while (ptr <= chunk.data:len() - 5) do
		local t = chunk.data:sub(ptr, ptr + 3)
		local l = string.byte(chunk.data:sub(ptr + 4, ptr + 4))
		local v = chunk.data:sub(ptr + 5, ptr + 4 + l)
		ptr = ptr + 5 + l

		if t and l and v then
			if     t == 'NAME' then name = v
			elseif t == 'IPAD' then ip = v
			elseif t == 'JSON' then port = v
			end
		end
	end

	if name and ip and port then
		-- get instance for SqueezeCenter
		local server = SlimServer(jnt, name)

		-- update SqueezeCenter address
		server:updateAddress(ip, port)

		if self.state == 'searching'
			or self.state == 'probing' then

			-- connect to server when searching or probing
			server:connect()
		end
	end
end


-- removes old servers
local function _squeezeCenterCleanup(self)
	local now = Framework:getTicks()

	local activeServer = self.currentPlayer and self.currentPlayer:getSlimServer()

	for i, server in SlimServer.iterate() do
		if not server:isConnected() and
			activeServer ~= server and
			now - server:getLastSeen() > DISCOVERY_TIMEOUT then
		
			log:info("Removing server ", server:getName())
			server:free()
		end
	end

	-- XXXX debug
	self:_debug()
end



-- init
-- Initializes the applet
function __init(self, ...)

	-- init superclass
	local obj = oo.rawnew(self, Applet(...))

	-- default poll list, udp broadcast
	obj.poll = { [ "255.255.255.255" ] = "255.255.255.255" }

	-- slim discovery socket
	obj.socket = SocketUdp(jnt,
			       function(...) _slimDiscoverySink(obj, ...) end)

	-- discovery timer
	obj.timer = Timer(DISCOVERY_PERIOD,
			  function() obj:_discover() end)

	-- initial state
	obj.currentPlayer = false
	obj.state = 'searching'

	-- start discovering
	-- FIXME we need a slight delay here to allow the settings to be loaded
	-- really the settings should be loaded before the applets start.
	obj.timer:restart(2000)

	-- subscribe to the jnt so that we get network/server notifications
	jnt:subscribe(obj)

	return obj
end


function _discover(self)
	log:debug("discover")

	-- Broadcast SqueezeCenter discovery
	for i, address in pairs(self.poll) do
		log:debug("sending to address ", address)
		self.socket:send(_slimDiscoverySource, address, PORT)
	end

	-- Special case Squeezenetwork
	if jnt:getUUID() then
---- XXXX
----		SlimServer(jnt, jnt:getSNHostname(), 9000, "SqueezeNetwork")
	end

	-- Remove SqueezeCenters that have not been seen for a while
	_squeezeCenterCleanup(self)


	if self.state == 'probing' and
		Framework:getTicks() > self.probeUntil then

		if self.currentPlayer and self.currentPlayer:getSlimServer() then
			self:_setState('connected')
		else
			self:_setState('searching')
		end
	end


	self.timer:restart(DISCOVERY_PERIOD)
end


function _setState(self, state)
	if self.state == state then
		return -- no change
	end

	-- restart discovery if we were disconnected
	if self.state == 'disconnected' then
		self.timer:restart(0)
	end

	self.state = state

	if state == 'disconnected' then
		self.timer:stop()
		self:_disconnect()

	elseif state == 'searching' then
		self.timer:restart(0)
		self:_connect()

	elseif state == 'connected' then
		self:_idleDisconnect()

	elseif state == 'probing' then
		self.probeUntil = Framework:getTicks() + 60000
		self.timer:restart(0)
		self:_connect()

	else
		log:error("unknown state=", state)
	end

	-- XXXX debug
	self:_debug()
end


function _debug(self)
	local now = Framework:getTicks()

	log:warn("----")
	log:warn("State: ", self.state)
	log:warn("CurrentPlayer: ", self.currentPlayer)
	if self.currentPlayer then
		log:warn("ActiveServer: ", self.currentPlayer:getSlimServer())
	end
	log:warn("Servers:")
	for i, server in SlimServer.iterate() do
		log:warn("\t", server:getName(), " connected=", server:isConnected(), " timeout=", DISCOVERY_TIMEOUT - (now - server:getLastSeen()))
	end
	log:warn("Players:")
	for i, player in Player.iterate() do
		log:warn("\t", player:getName(), " server=", player:getSlimServer())
	end
	log:warn("----")
end


-- connect to all servers
function _connect(self)
	for i, server in SlimServer:iterate() do
		server:connect()
	end
end


-- disconnect from all servers
function _disconnect(self)
	for i, server in SlimServer:iterate() do
		server:disconnect()
	end
end


-- disconnect from idle servers
function _idleDisconnect(self)
	local activeServer = self.currentPlayer and self.currentPlayer:getSlimServer()

	for i, server in SlimServer:iterate() do
		if server ~= activeServer then
			server:disconnect()
		else
			server:connect()
		end
	end
end


-- restart discovery if the player is disconnect from SqueezeCenter
function notify_playerDelete(self, player)
	log:info("playerDelete")

	-- start discovery looking for the player
	self:_setState('searching')
end


-- restart discovery if SqueezeCenter disconnects
function notify_serverDisconnected(self, slimserver)
	log:info("serverDisconnected")

	if not self.currentPlayer or self.currentPlayer:getSlimServer() ~= slimserver then
		return
	end

	-- start discovery looking for the player
	self:_setState('searching')
end


-- stop discovery if SqueezeCenter reconnects
function notify_serverConnected(self, slimserver)
	log:info("serverConnected")

	if not self.currentPlayer or self.currentPlayer:getSlimServer() ~= slimserver then
		return
	end

	-- start discovery looking for the player
	self:_setState('connected')
end


-- restart discovery on new network connection
function notify_networkConnected(self)
	log:info("networkConnected")

	if not self.currentPlayer or not self.currentPlayer:getSlimServer() then
		-- force re-connection to all servers
		self:_disconnect()
		self:_connect()
	else
		-- force re-connection to the current player
		self.currentPlayer:getSlimServer():disconnect()
		self.currentPlayer:getSlimServer():connect()
	end
end



function getCurrentPlayer(self)
	return self.currentPlayer
end


function setCurrentPlayer(self, player)
	if self.currentPlayer == player then
		return -- no change
	end

	-- update player
	log:info("selected player: ", player)
	self.currentPlayer = player
	jnt:notify("playerCurrent", player)

	-- restart discovery when we have no player
	if self.currentPlayer and self.currentPlayer:getSlimServer() then
		self:_setState('connected')
	else
		self:_setState('searching')
	end
end


function discoverPlayers(self)
	self:_setState("probing")
end


function connectPlayer(self)
	if self.currentPlayer and self.currentPlayer:getSlimServer() then
		self:_setState("connected")
	else
		self:_setState("searching")
	end
end


function disconnectPlayer(self)
	self:_setState("disconnected")
end


function iteratePlayers(self)
	return Player:iterate()
end


function iterateSqueezeCenters(self)
	return SlimServer:iterate()
end


function countConnectedPlayers(self)
	local count = 0
	for i, player in Player:iterate() do
		if player:isConnected() then
			count = count + 1
		end
	end

	return count
end


function countPlayers(self)
	local count = 0
	for i, player in Player:iterate() do
		count = count + 1
	end

	return count
end


function getPollList(self)
	return self.poll
end


function setPollList(self, poll)
	self.poll = poll

	-- get going with the new poll list
	self:discoverPlayers()
end



--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]

