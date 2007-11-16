
--[[
=head1 NAME

applets.Flickr.FlickrApplet - A screensaver displaying a Flickr photo stream.

=head1 DESCRIPTION

This screensaver displays random images every 10 seconds from the Flickr
picture website. It demonstrates using the network API in addition to
applet and screensavers concepts in Jive.

=head1 FUNCTIONS

Applet related methods are described in L<jive.Applet>. 
FlickrApplet overrides the following methods:

=cut
--]]


-- stuff we use
local pairs, ipairs, tostring = pairs, ipairs, tostring

local math             = require("math")
local table            = require("table")
local socket           = require("socket")

local oo               = require("loop.simple")

local Applet           = require("jive.Applet")
local Font             = require("jive.ui.Font")
local Framework        = require("jive.ui.Framework")
local Icon             = require("jive.ui.Icon")
local Label            = require("jive.ui.Label")
local Popup            = require("jive.ui.Popup")
local RadioButton      = require("jive.ui.RadioButton")
local RadioGroup       = require("jive.ui.RadioGroup")
local Textinput        = require("jive.ui.Textinput")
local Textarea         = require("jive.ui.Textarea")
local SimpleMenu       = require("jive.ui.SimpleMenu")
local Surface          = require("jive.ui.Surface")
local Window           = require("jive.ui.Window")
local SocketHttp       = require("jive.net.SocketHttp")
local RequestHttp      = require("jive.net.RequestHttp")
local json             = require("json")
                       
local log              = require("jive.utils.log").logger("applets.screensavers")

local EVENT_KEY_PRESS  = jive.ui.EVENT_KEY_PRESS
local EVENT_SCROLL     = jive.ui.EVENT_SCROLL
local EVENT_WINDOW_RESIZE = jive.ui.EVENT_WINDOW_RESIZE
local EVENT_CONSUME    = jive.ui.EVENT_CONSUME
local FRAME_RATE       = jive.ui.FRAME_RATE
local LAYER_FRAME      = jive.ui.LAYER_FRAME
local LAYER_CONTENT    = jive.ui.LAYER_CONTENT
local KEY_BACK         = jive.ui.KEY_BACK

local jnt              = jnt


module(...)
oo.class(_M, Applet)


local apiKey           = "18d9e492ca288b453a9cc6065c440d0c"
local transitionBoxOut
local transitionTopDown 
local transitionBottomUp 
local transitionLeftRight
local transitionRightLeft
local flickrTitleStyle = 'settingstitle'

function openScreensaver(self, menuItem)

	self.photoQueue = {}
	self.transitions = { transitionBoxOut, transitionTopDown, transitionBottomUp, transitionLeftRight, transitionRightLeft, Window.transitionFadeIn }

	local ok, err = self:displayNextPhoto()

	local label
	if ok then
		label = Label("label", self:string("SCREENSAVER_FLICKR_LOADING_PHOTO"))
	else
		label = Label("label", self:string("SCREENSAVER_FLICKR_ERROR") .. err)
	end
	
	self.window = self:_window(label)

	self:tieAndShowWindow(self.window)
	return self.window
end

function popupMessage(self, title, msg)
	local popup = Window("window", title)
	local text = Textarea("textarea", msg)
	popup:addWidget(text)

	popup:addListener(EVENT_KEY_PRESS | EVENT_SCROLL,
			  function()
				  popup:hide()
			  end)

	self:tieAndShowWindow(popup)
end


function openSettings(self, menuItem)
	local window = Window("window", menuItem.text, flickrTitleStyle)
	window:addWidget(SimpleMenu("menu",
		{
			{
				text = self:string("SCREENSAVER_FLICKR_DISPLAY"), 
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:displaySetting(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("SCREENSAVER_FLICKR_DELAY"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:timeoutSetting(menuItem)
					return EVENT_CONSUME
			end
			},
			{
				text = self:string("SCREENSAVER_FLICKR_FLICKR_ID"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineFlickrId(menuItem)
					return EVENT_CONSUME
				end
			},
			--[[
			{
				text = self:string("SCREENSAVER_FLICKR_TRANSITION"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineTransition(menuItem)
					return EVENT_CONSUME
				end
			},
			--]]
		}))

	self:tieAndShowWindow(window)
	return window
end


function defineFlickrId(self, menuItem)

    local window = Window("window", self:string("SCREENSAVER_FLICKR_FLICKR_ID"), flickrTitleStyle)

	local flickrid = self:getSettings()["flickr.idstring"]
	if flickrid == nil then
		flickrid = "Your ID"
	end

	local input = Textinput("textinput", flickrid,
		function(_, value)
			if #value < 4 then
				return false
			end

			log:warn("Input " .. value)
			self:setFlickrIdString(value)

			window:playSound("WINDOWSHOW")
			window:hide(Window.transitionPushLeft)
			return true
		end)

    local help = Textarea("help", self:string("SCREENSAVER_FLICKR_FLICKR_ID_HELP"))

    window:addWidget(help)
    window:addWidget(input)

    self:tieAndShowWindow(window)
    return window
end


function defineTransition(self, menuItem)
	local group = RadioGroup()

	local trans = self:getSettings()["flickr.transition"]
	
	local window = Window("window", menuItem.text, flickrTitleStyle)
	window:addWidget(SimpleMenu("menu",
		{
            {
                text = self:string("SCREENSAVER_FLICKR_TRANSITION_RANDOM"),
                icon = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTransition("random")
                    end,
                    trans == "random"
                ),
            },
            {
                text = self:string("SCREENSAVER_FLICKR_TRANSITION_INSIDE_OUT"),
                icon = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTransition("boxout")
                    end,
                    trans == "boxout"
                ),
	        },
 			{
                text = self:string("SCREENSAVER_FLICKR_TRANSITION_TOP_DOWN"),
				icon = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("topdown") 
				   end,
				   trans == "topdown"
				),
			},
			{ 
                text = self:string("SCREENSAVER_FLICKR_TRANSITION_BOTTOM_UP"),
				icon = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("bottomup") 
				   end,
				   display == "bottomup"
				),
			},
			{ 
                text = self:string("SCREENSAVER_FLICKR_TRANSITION_LEFT_RIGHT"),
				icon = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("leftright") 
				   end,
				   trans == "leftright"
				),
			},
			{ 
                text = self:string("SCREENSAVER_FLICKR_TRANSITION_RIGHT_LEFT"),
				icon = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("rightleft") 
				   end,
				   trans == "rightleft"
				),
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function displaySetting(self, menuItem)
	local group = RadioGroup()

	local display = self:getSettings()["flickr.display"]
	
	local window = Window("window", menuItem.text, flickrTitleStyle)
	window:addWidget(SimpleMenu("menu",
		{
            {
                text = self:string("SCREENSAVER_FLICKR_DISPLAY_OWN"),
                icon = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setDisplay("own")
                    end,
                    display == "own"
	            ),
            },
            {
                text = self:string("SCREENSAVER_FLICKR_DISPLAY_CONTACTS"),
                icon = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setDisplay("contacts")
                    end,
                    display == "contacts"
                ),
            },
 			{
				text = self:string("SCREENSAVER_FLICKR_DISPLAY_INTERESTING"), 
				icon = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setDisplay("interesting") 
				   end,
				   display == "interesting"
				),
			},
			{ 
				text = self:string("SCREENSAVER_FLICKR_DISPLAY_RECENT"), 
				icon = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setDisplay("recent") 
				   end,
				   display == "recent"
			   ),
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function timeoutSetting(self, menuItem)
	local group = RadioGroup()

	local timeout = self:getSettings()["flickr.timeout"]

	local window = Window("window", menuItem.text, flickrTitleStyle)
	window:addWidget(SimpleMenu("menu",
		{
			{
				text = self:string("SCREENSAVER_FLICKR_DELAY_10_SEC"),
				icon = RadioButton("radio", group, function() self:setTimeout(10000) end, timeout == 10000),
			},
			{ 
				text = self:string("SCREENSAVER_FLICKR_DELAY_20_SEC"),
				icon = RadioButton("radio", group, function() self:setTimeout(20000) end, timeout == 20000),
			},
			{ 
				text = self:string("SCREENSAVER_FLICKR_DELAY_30_SEC"),
				icon = RadioButton("radio", group, function() self:setTimeout(30000) end, timeout == 30000),
			},
			{
				text = self:string("SCREENSAVER_FLICKR_DELAY_1_MIN"),
				icon = RadioButton("radio", group, function() self:setTimeout(60000) end, timeout == 60000),
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function setDisplay(self, display)
	if self:getSettings()["flickr.id"] == "" and (display == "own" or display == "contacts") then
		self:popupMessage(self:string("SCREENSAVER_FLICKR_ERROR"), self:string("SCREENSAVER_FLICKR_INVALID_DISPLAY_OPTION"))
	else
		self:getSettings()["flickr.display"] = display
		self:storeSettings()
	end
end


function setTimeout(self, timeout)
	self:getSettings()["flickr.timeout"] = timeout
	self:storeSettings()
end

function setFlickrId(self, flickrid)
	self:getSettings()["flickr.id"] = flickrid
	self:storeSettings()
end

function setFlickrIdString(self, flickridString)
	self:getSettings()["flickr.idstring"] = flickridString
	self:getSettings()["flickr.id"] = ""
	self:storeSettings()
	self:resolveFlickrIdByEmail(flickridString)
end

function setTransition(self, trans)
	self:getSettings()["flickr.transition"] = trans
	self:storeSettings()
end


function displayNextPhoto(self)

	-- fill photo queue if it's empty
	if #self.photoQueue == 0 then
		return self:_requestPhoto()
	end

	-- pick random photo from response
	local photo = table.remove(self.photoQueue, math.random(#self.photoQueue))

	local host, port, path = self:_getPhotoUrl(photo)
	log:info("photo URL: ", host, ":", port, path)

	-- request photo
	local http = SocketHttp(jnt, host, port, "flickr2")
	local req = RequestHttp(function(chunk, err)
			if chunk then
				local srf = Surface:loadImageData(chunk, #chunk)
				self:_loaded(photo, srf)
			end
		end,
		'GET',
		path)
	http:fetch(req)

	return true
end


function _requestPhoto(self)

	local method, args

	local displaysetting = self:getSettings()["flickr.display"]
	if displaysetting == nil then
		displaysetting = "interesting"
	end

	if displaysetting == "recent" then
		method = "flickr.photos.getRecent"
		args = { per_page = 1 }
	elseif displaysetting == "contacts" then
		method = "flickr.photos.getContactsPublicPhotos"
		args = { per_page = 100, user_id = self:getSettings()["flickr.id"], include_self = 1 }
	elseif displaysetting == "own" then
		method = "flickr.people.getPublicPhotos"
		args = { per_page = 100, user_id = self:getSettings()["flickr.id"] }
	else 
        method = "flickr.interestingness.getList"
        args = { per_page = 100 }
	end

	local host, port, path = self:_getRest(method, args)
	if host then
		log:warn("getRecent URL: ", host, ":", port, path)

		local socket = SocketHttp(jnt, host, port, "flickr")
		local req = RequestHttp(
			function(chunk, err)
				self:_getPhotoList(chunk, err)
			end,
			'GET',
			path)
		socket:fetch(req)

		if self.timer then
			self.window:removeTimer(self.timer)
			self.timer = nil
		end
		return true
	else
		return false, port -- port is err!
	end
end


function _window(self, ...)
	local window = Window("flickr")

	-- black window background
	local w, h = window:getSize()
	local bg  = Surface:newRGBA(w, h)
	bg:filledRectangle(0, 0, w, h, 0x000000FF)
	window:addWidget(Icon("background", bg))

	for i, v in ipairs{...} do
		window:addWidget(v)
	end

	-- close the window on left
	window:addListener(EVENT_KEY_PRESS,
		function(evt)
		   if evt:getKeycode() == KEY_BACK then
			   window:hide()
			   self.photoQueue = {}
			   return EVENT_CONSUME
		   end
		end)

	window:addListener(EVENT_WINDOW_RESIZE,
		function(evt)
		   local icon = self:_makeIcon(self.photo, self.photoSrf)
		   self.window:addWidget(icon)
		end)

	self:tieWindow(window)
	return window
end


function _getPhotoList(self, chunk, err)
	if chunk then

		log:warn("got chunk ", chunk)
		local obj = json.decode(chunk)

		-- add photos to queue
		for i,photo in ipairs(obj.photos.photo) do
			self.photoQueue[#self.photoQueue + 1] = photo
		end

		self:displayNextPhoto()
	end
end


function _makeIcon(self, photo, srf)
	-- reposition icon
	local sw, sh = Framework:getScreenSize()

	local w,h = srf:getSize()
	if w < h then
		srf = srf:rotozoom(0, sw / w, 1)
	else
		srf = srf:rotozoom(-90, sw / h, 1)
	end

	w,h = srf:getSize()
	local x, y = (sw - w) / 2, (sh - h) / 2

	local fontBold = Font:load("fonts/FreeSansBold.ttf", 10)
	local fontRegular = Font:load("fonts/FreeSans.ttf", 10)

    -- empty image to draw onto
	local totImg = Surface:newRGBA(sw, sh)
        totImg:filledRectangle(0, 0, sw, sh, 0x000000FF)

	-- draw image
	srf:blit(totImg, x, y)

	-- draw black rectangle for text
	totImg:filledRectangle(0,sh-20,sw,sh, 0x000000FF)

	-- draw photo owner
	local txt1 = Surface:drawText(fontBold, 0xFFFFFFFF, photo.ownername)
	txt1:blit(totImg, 5, sh-15)

	-- draw photo title
	if photo.title then
		local titleWidth = fontRegular:width(photo.title)

		local txt2 = Surface:drawText(fontRegular, 0xFFFFFFFF, photo.title)
		txt2:blit(totImg, sw - 5 - titleWidth, sh-15)
	end

	local icon = Icon("image", totImg)
	icon:setPosition(0, 0)

	return icon
end


function _loaded(self, photo, srf)
	log:debug("photo loaded")

	self.photo = photo
	self.photoSrf = srf

	local icon = self:_makeIcon(photo, srf)

	self.window = self:_window(icon)

    local transition
	local trans = self:getSettings()["flickr.transition"]
	if trans == "random" then
		transition = self.transitions[math.random(#self.transitions)]
	elseif trans == "boxout" then
		transition = transitionBoxOut
	elseif trans == "topdown" then
		transition = transitionTopDown
	elseif trans == "bottomup" then
		transition = transitionBottomUp
	elseif trans == "leftright" then
		transition = transitionLeftRight
	elseif trans == "rightleft" then
		transition = transitionRightLeft
	end	

	self.window:showInstead(transition)

	-- start timer for next photo in timeout seconds
	local timeout = self:getSettings()["flickr.timeout"]
	self.timer = self.window:addTimer(timeout,
		function()
		     self:displayNextPhoto()
		end)
end


function _getRest(self, method, args)
	local url = {}	
	url[#url + 1] = "method=" .. method

	for k,v in pairs(args) do
		url[#url + 1] = k .. "=" .. v
	end

	url[#url + 1] = "api_key=" .. apiKey
	url[#url + 1] = "extras=owner_name"
	url[#url + 1] = "format=json"
	url[#url + 1] = "nojsoncallback=1"
	
	local ip, err = socket.dns.toip("api.flickr.com")

	if ip then
		return ip, 80, "/services/rest/?" .. table.concat(url, "&")
	else
		self:popupMessage(self:string("SCREENSAVER_FLICKR_ERROR"), self:string("SCREENSAVER_FLICKR_NETWORK_ERROR"))
		log:error(err)
		return nil, err
	end
end


function _findFlickrIdByEmail(self, searchText)
	local url = "method=flickr.people.findByEmail"
	url = url .. "&api_key=" .. apiKey
	url = url .. "&format=json"
	url = url .. "&nojsoncallback=1"
	url = url .. "&find_email=" .. searchText

	local ip, err = socket.dns.toip("api.flickr.com")

	if ip then
		return ip, 80, "/services/rest/?" .. url
	else
		self:popupMessage(self:string("SCREENSAVER_FLICKR_ERROR"), self:string("SCREENSAVER_FLICKR_NETWORK_ERROR"))
		log:error(err)
		return nil, err
	end
end


function _findFlickrIdByUserID(self, searchText)
	local url = "method=flickr.people.findByUsername"
	url = url .. "&api_key=" .. apiKey
	url = url .. "&format=json"
	url = url .. "&nojsoncallback=1"
	url = url .. "&username=" .. searchText

	local ip, err = socket.dns.toip("api.flickr.com")

	if ip then
		return ip, 80, "/services/rest/?" .. url
	else
		self:popupMessage(self:string("SCREENSAVER_FLICKR_ERROR"), self:string("SCREENSAVER_FLICKR_NETWORK_ERROR"))
		log:error(err)
		return nil, err
	end
end



function resolveFlickrIdByEmail(self, searchText)
	-- check whether searchText is an email
	local host, port, path = self:_findFlickrIdByEmail(searchText)
	log:info("find by email: ", host, ":", port, path)

	local http = SocketHttp(jnt, host, port, "flickr3")
	local req = RequestHttp(function(chunk, err)
			if chunk then
				local obj = json.decode(chunk)
				if obj.stat == "ok" then
					log:info("flickr id found: " .. obj.user.nsid)
					self:setFlickrId(obj.user.nsid)
				else
					log:warn("search by email failed")
					log:warn(searchText)
					self:resolveFlickrIdByUsername(searchText)
				end
			end
		end,
		'GET',
		path)
	http:fetch(req)

	return true
end

function resolveFlickrIdByUsername(self, searchText)
	-- check whether searchText is a username
	local host, port, path = self:_findFlickrIdByUserID(searchText)
	log:info("find by userid: ", host, ":", port, path)
	local http = SocketHttp(jnt, host, port, "flickr4")
	local req = RequestHttp(function(chunk, err)
			if chunk then
				local obj = json.decode(chunk)
				if obj.stat == "ok" then
					log:info("flickr id found: " .. obj.user.nsid)
					self:setFlickrId(obj.user.nsid)
				else
					log:warn("search by userid failed")
					self:popupMessage(self:string("SCREENSAVER_FLICKR_ERROR"), self:string("SCREENSAVER_FLICKR_USERID_ERROR"))
				end
			end
		end,
		'GET',
		path)
	http:fetch(req)

	return true
end


function _getPhotoUrl(self, photo, size)
	local server = "farm" .. photo.farm .. ".static.flickr.com"
	local path = "/" .. photo.server .. "/" .. photo.id .. "_" .. photo.secret .. (size or "") .. ".jpg"

	return socket.dns.toip(server), 80, path
end


function transitionBoxOut(oldWindow, newWindow)
	local frames = FRAME_RATE * 2 -- 2 secs
	local screenWidth, screenHeight = Framework:getScreenSize()
	local incX = screenWidth / frames / 2
	local incY = screenHeight / frames / 2
	local x = screenWidth / 2
	local y = screenHeight / 2
	local i = 0

	return function(widget, surface)
       local adjX = i * incX
       local adjY = i * incY

       newWindow:draw(surface, LAYER_FRAME)
       oldWindow:draw(surface, LAYER_CONTENT)

       surface:setClip(x - adjX, y - adjY, adjX * 2, adjY * 2)
       newWindow:draw(surface, LAYER_CONTENT)

       i = i + 1
       if i == frames then
	       Framework:_killTransition()
       end
    end
end

function transitionBottomUp(oldWindow, newWindow)
    local frames = FRAME_RATE * 2 -- 2 secs
    local screenWidth, screenHeight = Framework:getScreenSize()
    local incY = screenHeight / frames
    local i = 0

    return function(widget, surface)
        local adjY = i * incY

        newWindow:draw(surface, LAYER_FRAME)
        oldWindow:draw(surface, LAYER_CONTENT)

        surface:setClip(0, screenHeight-adjY, screenWidth, screenHeight)
        newWindow:draw(surface, LAYER_CONTENT)

        i = i + 1
        if i == frames then
            Framework:_killTransition()
        end
    end
end

function transitionTopDown(oldWindow, newWindow)
    local frames = FRAME_RATE * 2 -- 2 secs
    local screenWidth, screenHeight = Framework:getScreenSize()
    local incY = screenHeight / frames
    local i = 0

    return function(widget, surface)
        local adjY = i * incY

        newWindow:draw(surface, LAYER_FRAME)
        oldWindow:draw(surface, LAYER_CONTENT)

        surface:setClip(0, 0, screenWidth, adjY)
        newWindow:draw(surface, LAYER_CONTENT)

        i = i + 1
        if i == frames then
            Framework:_killTransition()
        end
    end
end

function transitionLeftRight(oldWindow, newWindow)
    local frames = FRAME_RATE * 2 -- 2 secs
    local screenWidth, screenHeight = Framework:getScreenSize()
    local incX = screenWidth / frames
    local i = 0

    return function(widget, surface)
        local adjX = i * incX

        newWindow:draw(surface, LAYER_FRAME)
        oldWindow:draw(surface, LAYER_CONTENT)

        surface:setClip(0, 0, adjX, screenHeight)
        newWindow:draw(surface, LAYER_CONTENT)

        i = i + 1
        if i == frames then
                Framework:_killTransition()
        end
    end
end

function transitionRightLeft(oldWindow, newWindow)
    local frames = FRAME_RATE * 2 -- 2 secs
    local screenWidth, screenHeight = Framework:getScreenSize()
    local incX = screenWidth / frames
    local i = 0

    return function(widget, surface)
        local adjX = i * incX

        newWindow:draw(surface, LAYER_FRAME)
        oldWindow:draw(surface, LAYER_CONTENT)

        surface:setClip(screenWidth-adjX, 0, screenWidth, screenHeight)
        newWindow:draw(surface, LAYER_CONTENT)

        i = i + 1
        if i == frames then
            Framework:_killTransition()
        end
    end
end


-- applet skin
function skin(self, s)
	s.flickr = {}
	s.flickr.layout = Window.noLayout
	s.flickr.font = Font:load("fonts/FreeSans.ttf", 10)
end


--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]

