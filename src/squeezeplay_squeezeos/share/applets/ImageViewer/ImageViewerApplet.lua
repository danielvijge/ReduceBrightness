
--[[
=head1 NAME

applets.ImageViewer.ImageViewerApplet - Slideshow of images from /media/*/images directory

=head1 DESCRIPTION

Finds images from removable media and displays them as a slideshow

=head1 FUNCTIONS

Applet related methods are described in L<jive.Applet>. 

=cut
--]]


-- stuff we use
local setmetatable, tonumber, tostring, ipairs = setmetatable, tonumber, tostring, ipairs

local io			= require("io")
local oo			= require("loop.simple")
local math			= require("math")
local table			= require("jive.utils.table")
local string		= require("jive.utils.string")
local lfs			= require('lfs')

local Applet		= require("jive.Applet")
local appletManager	= require("jive.AppletManager")
local Checkbox		= require("jive.ui.Checkbox")
local Event			= require("jive.ui.Event")
local Framework		= require("jive.ui.Framework")
local Font			= require("jive.ui.Font")
local Icon			= require("jive.ui.Icon")
local Label			= require("jive.ui.Label")
local Group			= require("jive.ui.Group")
local Popup			= require("jive.ui.Popup")
local RadioButton	= require("jive.ui.RadioButton")
local RadioGroup	= require("jive.ui.RadioGroup")
local Surface		= require("jive.ui.Surface")
local Window		= require("jive.ui.Window")
local SimpleMenu	= require("jive.ui.SimpleMenu")
local Task			= require("jive.ui.Task")
local Timer			= require("jive.ui.Timer")
local Process		= require("jive.net.Process")
local ContextMenuWindow      = require("jive.ui.ContextMenuWindow")
local Textarea               = require("jive.ui.Textarea")

local debug			= require("jive.utils.debug")

local ImageSource		= require("applets.ImageViewer.ImageSource")
local ImageSourceCard	= require("applets.ImageViewer.ImageSourceCard")
local ImageSourceHttp	= require("applets.ImageViewer.ImageSourceHttp")
local ImageSourceFlickr	= require("applets.ImageViewer.ImageSourceFlickr")
local ImageSourceServer	= require("applets.ImageViewer.ImageSourceServer")

local FRAME_RATE       = jive.ui.FRAME_RATE
local LAYER_FRAME      = jive.ui.LAYER_FRAME
local LAYER_CONTENT    = jive.ui.LAYER_CONTENT

local jnt = jnt
local jiveMain = jiveMain

local MIN_SCROLL_INTERVAL = 750

module(..., Framework.constants)
oo.class(_M, Applet)

local transitionBoxOut
local transitionTopDown 
local transitionBottomUp 
local transitionLeftRight
local transitionRightLeft

function initImageSource(self, imgSourceOverride)
	log:info("init image viewer")

	self.imgSource = nil
	self.listCheckCount = 0
	self.initialized = false

	if imgSourceOverride then
		self.imgSource = imgSourceOverride
	else
		local src = self:getSettings()["source"]

		if src == "card" then
			self.imgSource = ImageSourceCard(self)
		elseif src == "http" then
			self.imgSource = ImageSourceHttp(self)
		elseif src == "flickr" then
			self.imgSource = ImageSourceFlickr(self)
		end
	end

	self.transitions = { transitionBoxOut, transitionTopDown, transitionBottomUp, transitionLeftRight, transitionRightLeft, 
		Window.transitionFadeIn, Window.transitionPushLeft, Window.transitionPushRight }
end


function openImageViewer(self)
	-- two item menu that shows start slideshow and settings
	local window = Window("text_list", self:string('IMAGE_VIEWER'))
	window:addWidget(
		SimpleMenu("menu",
		{
			{
				text = self:string("IMAGE_VIEWER_START_SLIDESHOW"), 
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:startSlideshow(menuItem, false)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_SETTINGS"), 
				sound = "WINDOWSHOW",
				callback = function()
					self:openSettings()
					return EVENT_CONSUME
				end
			},
		}
		)
	)
	self:tieAndShowWindow(window)
	return window
end


function startSlideshow(self, menuItem, isScreensaver, imgSourceOverride)
	log:info("start image viewer")

	-- initialize the chosen image source
	self:initImageSource(imgSourceOverride)
	self.initialized = true
	self.isScreensaver = isScreensaver
	self:showInitWindow()
	self:startSlideshowWhenReady()
end


function showInitWindow(self)
	local popup = Window("black_popup", "")

	popup:setAutoHide(true)
	popup:setShowFrameworkWidgets(false)

	local label = Label("text", "")
	local sublabel = Label("subtext", self:string("IMAGE_VIEWER_LOADING"))
	local icon = Icon("icon_photo_loading")

	self.imgSource:updateLoadingIcon(icon)
	
	popup:addWidget(label)
	popup:addWidget(icon)
	popup:addWidget(sublabel)
	popup:focusWidget(sublabel)

	self:applyScreensaverWindow(popup)
	popup:addListener(EVENT_KEY_PRESS | EVENT_MOUSE_PRESS,
			  function()
				popup:playSound("WINDOWHIDE")
				popup:hide()
			  end)

	self:tieAndShowWindow(popup, Window.transitionFadeIn)

end

function startSlideshowWhenReady(self)
	-- stop timer
	if self.nextSlideTimer != nil then
		self.nextSlideTimer:stop()
	end

	if not self.imgSource:listReady() then
		self.listCheckCount = self.listCheckCount + 1

		log:debug("self.listCheckCount: ", self.listCheckCount)

		if self.listCheckCount == 50 then
			if self.nextSlideTimer != nil then
				self.nextSlideTimer:stop()
			end
			self.imgSource:listNotReadyError()
			return
		end

		-- try again in a few moments
		log:debug("image list not ready yet...")
		if not self.nextSlideTimer then
			self.nextSlideTimer = Timer(200,
				function()
					self:startSlideshowWhenReady()
				end,
				true)
		end
		self.nextSlideTimer:restart()		
		return
	end


	-- image list is ready
	self.imgSource:nextImage(self:getSettings()["ordering"])
	self:displaySlide()
end

function showTextWindow(self)
	local window = ContextMenuWindow(nil, nil, true)
	local text = Textarea("multiline_text", self.imgSource:getMultilineText())
	window:addWidget(text)
	window:setShowFrameworkWidgets(false)

	if self.isScreensaver then
		self:applyScreensaverWindow(window)
	end

	window:addActionListener("back", self,  function ()
							window:hide()
							return EVENT_CONSUME
						end)

	window:show() 
end


function setupEventHandlers(self, window)

	local nextSlideAction = function (self)
		log:debug("request next slide")
		self.imgSource:nextImage(self:getSettings()["ordering"])
		self:displaySlide()
		return EVENT_CONSUME
	end

	local previousSlideAction = function (self, window)
		log:debug("request prev slide")
		self.useFastTransition = true
		self.imgSource:previousImage(self:getSettings()["ordering"])
		self:displaySlide()
		return EVENT_CONSUME
	end

	local showTextWindowAction = function (self)
		if self.imgSource:getText() then
			self:showTextWindow()
		end
		return EVENT_CONSUME
	end

	--todo add takes user to meta data page
	window:addActionListener("add", self, showTextWindowAction)
	window:addActionListener("go", self, nextSlideAction)
	window:addActionListener("up", self, nextSlideAction)
	window:addActionListener("play", self, nextSlideAction)
	window:addActionListener("down", self, previousSlideAction)
	window:addActionListener("back", self, function () return EVENT_UNUSED end)

	window:addListener(EVENT_MOUSE_DOWN | EVENT_KEY_PRESS | EVENT_KEY_HOLD | EVENT_IR_PRESS | EVENT_SCROLL,
		function(event)
			local type = event:getType()
			local keyPress

			-- next slide on touch 
			if type == EVENT_MOUSE_DOWN then
				self.imgSource:nextImage(self:getSettings()["ordering"])
				self:displaySlide()
				return EVENT_CONSUME
			elseif type == EVENT_SCROLL then
				local scroll = event:getScroll()

				local dir
				if scroll > 0 then
					dir = 1
				else
					dir = -1
				end
				local now = Framework:getTicks()
				if not self.lastScrollT or
				  self.lastScrollT + MIN_SCROLL_INTERVAL < now or
				  self.lastScrollDir ~= dir then
				        --scrolling a lot or a little only moves by one, since image fetching is relatively slow
					self.lastScrollT = now
					self.lastScrollDir = dir
					if scroll > 0 then
						return nextSlideAction(self)
					else
						return previousSlideAction(self)
					end
				end
				return EVENT_CONSUME

			end

			return EVENT_UNUSED
        end
	)
end


--service method
function registerRemoteScreensaver(self, serverData)
	appletManager:callService("addScreenSaver",
			serverData.text,
			"ImageViewer",
			"openRemoteScreensaver", _, _, 100,
			"closeRemoteScreensaver",
			serverData,
			serverData.id
		)
end


--service method
function unregisterRemoteScreensaver(self, id)
	appletManager:callService("removeScreenSaver", "ImageViewer", "openRemoteScreensaver", _, id)
end


function openRemoteScreensaver(self, force, serverData)
	self:startSlideshow(_, true, ImageSourceServer(self, serverData))
end

function closeRemoteScreensaver(self, force, serverData)
	if self.window then
		self.window:hide()
	end
	self.window = nil
end

function free(self)
	log:info("destructor of image viewer")
	if self.window then
		self.window:setAllowScreensaver(true)
	end

	--stop timers
	if self.nextSlideTimer then
		self.nextSlideTimer:stop()
	end
	if self.checkFotoTimer then
		self.checkFotoTimer:stop()
	end

	return true
end


function applyScreensaverWindow(self, window)
	if self.serverData and not self.serverData.allowMotion then
		window:addListener(EVENT_MOTION,
			function()
				window:hide(Window.transitionNone)
				return EVENT_CONSUME
			end)
	end
	local manager = appletManager:getAppletInstance("ScreenSavers")
	manager:screensaverWindow(window, true, {"add", "go", "play", "up", "down", "back"})
end


function displaySlide(self)
	if not self.initialized then
		self:initImageSource()
		self.initialized = true
	end

	-- stop timer
	if self.checkFotoTimer then
		self.checkFotoTimer:stop()
	end

	if self.nextSlideTimer and self.nextSlideTimer:isRunning() then
		--restart next slide timer to give this image a chance, can happen when displaySlide was manually trigger
		self.nextSlideTimer:restart()
	end

	if not self.imgSource:imageReady() then
		-- try again in a few moments
		log:debug("image not ready, try again...")
--		self.checkFotoTimer = Timer(1000, --hmm, this seems to enforce a second wait even if response is fast.... todo have image sink trigger this instead
		--todo: also, might this run continuously on a failure even if the applet is complete.
		if not self.checkFotoTimer then
			self.checkFotoTimer = Timer(200, --hmm, this seems to enforce a second wait even if response is fast....
				function()
					self:displaySlide()
				end,
				true)
		end
		self.checkFotoTimer:restart()
		return
	end

	log:debug("image rendering")

	--stop next slider Timer since a) we have a good image and, b) this call to displaySlide may have been manually triggered
	if self.nextSlideTimer then
		self.nextSlideTimer:stop()
	end

	-- get device orientation and features
	local screenWidth, screenHeight = Framework:getScreenSize()
	local deviceCanRotate = false
	
	-- FIXME: better detection for device type
	if ((screenWidth == 240) and (screenHeight == 320)) then
		-- Jive device
		deviceCanRotate = true
	end
	local rotation = self:getSettings()["rotation"]
	local fullScreen = self:getSettings()["fullscreen"]
	local ordering = self:getSettings()["ordering"]
	local textinfo = self:getSettings()["textinfo"]

	local deviceLandscape = ((screenWidth/screenHeight) > 1)

	local image = self.imgSource:getImage()
	if image != nil then
		local w, h = image:getSize()
		if self.imgSource:useAutoZoom() then
			local imageLandscape = ((w/h) > 1)

			-- determine whether to rotate
			if (rotation == "yes") or (rotation == "auto" and deviceCanRotate) then
				-- rotation allowed
				if deviceLandscape != imageLandscape then
					-- rotation needed, so let's do it
					image = image:rotozoom(-90, 1, 1)
					w, h = image:getSize()
				end
			end

			-- determine scaling factor
			local zoomX = screenWidth / w
			local zoomY = screenHeight / h
			local zoom = 1

			--[[
			log:info("pict " .. w .. "x" .. h)
			log:info("screen " .. screenWidth .. "x" .. screenHeight)
			log:info("zoomX " .. zoomX)
			log:info("zoomY " .. zoomY)
			log:info("deviceCanRotate " .. tostring(deviceCanRotate))
			log:info("rotation " .. rotation)
			log:info("fullscreen " .. tostring(fullScreen))
			--]]

			if fullScreen then
				zoom = math.max(zoomX, zoomY)
			else
				zoom = math.min(zoomX, zoomY)
			end

			-- scale image
			image = image:rotozoom(0, zoom, 1)
			w, h = image:getSize()
		end

		-- place scaled image centered to empty picture
		local totImg = Surface:newRGBA(screenWidth, screenHeight)
		totImg:filledRectangle(0, 0, screenWidth, screenHeight, 0x000000FF)
		local x, y = (screenWidth - w) / 2, (screenHeight - h) / 2

		-- draw image
		image:blit(totImg, x, y)

		image = totImg

		if textinfo then
			-- add text to image
			local txtLeft, txtCenter, txtRight = self.imgSource:getText()

			if txtLeft or txtCenter or txtRight then
				image:filledRectangle(0,screenHeight-20,screenWidth,screenHeight, 0x000000FF)
				local fontBold = Font:load("fonts/FreeSansBold.ttf", 10)
				local fontRegular = Font:load("fonts/FreeSans.ttf", 10)

				if txtLeft then
					-- draw left text
					local txt1 = Surface:drawText(fontBold, 0xFFFFFFFF, txtLeft)
					txt1:blit(image, 5, screenHeight-15 - fontBold:offset())
				end

				if txtCenter then
					-- draw center text
					local titleWidth = fontRegular:width(txtCenter)
					local txt2 = Surface:drawText(fontRegular, 0xFFFFFFFF, txtCenter)
					txt2:blit(image, (screenWidth-titleWidth)/2, screenHeight-15-fontRegular:offset())
				end

				if txtRight then
					-- draw right text
					local titleWidth = fontRegular:width(txtRight)
					local txt3 = Surface:drawText(fontRegular, 0xFFFFFFFF, txtRight)
					txt3:blit(image, screenWidth-5-titleWidth, screenHeight-15-fontRegular:offset())
				end
			end
		end

		local window = Window('window')
		window:addWidget(Icon("icon", image))

		if self.isScreensaver then
			self:applyScreensaverWindow(window)
		end

		self:setupEventHandlers(window)

		-- replace the window if it's already there
		if self.window then
			self:tieWindow(window)
			local transition
			if self.useFastTransition then
				transition = Window.transitionFadeIn
				self.useFastTransition = false
			else
				transition = self:getTransition()
			end
			self.window = window
			self.window:showInstead(transition)
		-- otherwise it's new
		else
			self.window = window
			self:tieAndShowWindow(window, window.transitionFadeIn) -- fade in for smooth consistent start 
		end

		-- no screensavers por favor
		self.window:setAllowScreensaver(false)

		--no iconbar
		self.window:setShowFrameworkWidgets(false)

		-- start timer for next photo in 'delay' seconds
		local delay = self:getSettings()["delay"]
		self.nextSlideTimer = self.window:addTimer(delay,
			function()
				self.imgSource:nextImage(self:getSettings()["ordering"])
				self:displaySlide()
			end)
	else
		log:info(self.imgSource)

		self.imgSource:popupMessage("error", "invalid image object found!")
	end
end


-- Configuration menu

function openSettings(self)
	log:info("image viewer settings")
	self:initImageSource()

	local window = Window("text_list", self:string("IMAGE_VIEWER_SETTINGS"), 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
			{
				text = self:string("IMAGE_VIEWER_SOURCE"), 
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineSource(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_SOURCE_SETTINGS"), 
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:sourceSpecificSettings(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_DELAY"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineDelay(menuItem)
					return EVENT_CONSUME
			end
			},
			{
				text = self:string("IMAGE_VIEWER_ORDERING"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineOrdering(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_TRANSITION"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineTransition(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_ROTATION"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineRotation(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_ZOOM"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineFullScreen(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_TEXTINFO"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineTextInfo(menuItem)
					return EVENT_CONSUME
				end
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function openMinimalSettings(self)
	log:info("image viewer settings 2")
	self:initImageSource()

	local window = Window("text_list", self:string("IMAGE_VIEWER_SETTINGS"), 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
			{
				text = self:string("IMAGE_VIEWER_DELAY"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineDelay(menuItem)
					return EVENT_CONSUME
			end
			},
			{
				text = self:string("IMAGE_VIEWER_TRANSITION"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineTransition(menuItem)
					return EVENT_CONSUME
				end
			},
			{
				text = self:string("IMAGE_VIEWER_TEXTINFO"),
				sound = "WINDOWSHOW",
				callback = function(event, menuItem)
					self:defineTextInfo(menuItem)
					return EVENT_CONSUME
				end
			},
		}))

	self:tieAndShowWindow(window)
	return window
end

function sourceSpecificSettings(self, menuItem)
	local window = Window("window", menuItem.text)

	window = self.imgSource:settings(window)

	self:tieAndShowWindow(window)
	return window
end

function defineOrdering(self, menuItem)
	local group = RadioGroup()

	local trans = self:getSettings()["ordering"]
	
	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
	{
            {
                text = self:string("IMAGE_VIEWER_ORDERING_SEQUENTIAL"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setOrdering("sequential")
                    end,
                    trans == "sequential"
                ),
            },
            {
                text = self:string("IMAGE_VIEWER_ORDERING_RANDOM"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setOrdering("random")
                    end,
                    trans == "random"
                )
			},
		}))

	self:tieAndShowWindow(window)
	return window
end

function defineTransition(self, menuItem)
	local group = RadioGroup()

	local trans = self:getSettings()["transition"]
	
	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
	{
            {
                text = self:string("IMAGE_VIEWER_TRANSITION_RANDOM"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTransition("random")
                    end,
                    trans == "random"
                ),
            },
            {
                text = self:string("IMAGE_VIEWER_TRANSITION_FADE"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTransition("fade")
                    end,
                    trans == "fade"
                )
	},
            {
                text = self:string("IMAGE_VIEWER_TRANSITION_INSIDE_OUT"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTransition("boxout")
                    end,
                    trans == "boxout"
                )
	},
 			{
                text = self:string("IMAGE_VIEWER_TRANSITION_TOP_DOWN"),
		style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("topdown") 
				   end,
				   trans == "topdown"
				),
			},
			{ 
                text = self:string("IMAGE_VIEWER_TRANSITION_BOTTOM_UP"),
		style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("bottomup") 
				   end,
				   display == "bottomup"
				),
			},
			{ 
                text = self:string("IMAGE_VIEWER_TRANSITION_LEFT_RIGHT"),
		style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("leftright") 
				   end,
				   trans == "leftright"
				),
			},
			{ 
                text = self:string("IMAGE_VIEWER_TRANSITION_RIGHT_LEFT"),
		style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("rightleft") 
				   end,
				   trans == "rightleft"
				),
			},
			{ 
                text = self:string("IMAGE_VIEWER_TRANSITION_PUSH_LEFT"),
		style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("pushleft") 
				   end,
				   trans == "pushleft"
				),
			},
			{ 
                text = self:string("IMAGE_VIEWER_TRANSITION_PUSH_RIGHT"),
		style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
					   self:setTransition("pushright") 
				   end,
				   trans == "pushright"
				),
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function defineSource(self, menuItem)
	local group = RadioGroup()

	local source = self:getSettings()["source"]
	
	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
            {
                text = self:string("IMAGE_VIEWER_SOURCE_CARD"),
				style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setSource("card")
                    end,
                    source == "card"
	            ),
            },
            {
                text = self:string("IMAGE_VIEWER_SOURCE_HTTP"),
				style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setSource("http")
                    end,
                    source == "http"
                ),
            },
            --[[
			{
                text = self:string("IMAGE_VIEWER_SOURCE_SC"),
				style = 'item_choice',
           	    check = RadioButton(
					"radio",
    	            group,
    	            function()
    	                self:setSource("sc")
    	            end,
    	            source == "sc"
	            ),
            },           
			--]]
 			{
				text = self:string("IMAGE_VIEWER_SOURCE_FLICKR"), 
				style = 'item_choice',
				check = RadioButton(
				   "radio", 
				   group, 
				   function() 
                        self:setSource("flickr")
				   end,
				   source == "flickr"
				),
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function defineDelay(self, menuItem)
	local group = RadioGroup()

	local delay = self:getSettings()["delay"]

	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
			{
				text = self:string("IMAGE_VIEWER_DELAY_10_SEC"),
				style = 'item_choice',
				check = RadioButton("radio", group, function() self:setDelay(10000) end, delay == 10000),
			},
			{ 
				text = self:string("IMAGE_VIEWER_DELAY_20_SEC"),
				style = 'item_choice',
				check = RadioButton("radio", group, function() self:setDelay(20000) end, delay == 20000),
			},
			{ 
				text = self:string("IMAGE_VIEWER_DELAY_30_SEC"),
				style = 'item_choice',
				check = RadioButton("radio", group, function() self:setDelay(30000) end, delay == 30000),
			},
			{
				text = self:string("IMAGE_VIEWER_DELAY_1_MIN"),
				style = 'item_choice',
				check = RadioButton("radio", group, function() self:setDelay(60000) end, delay == 60000),
			},
		}))

	self:tieAndShowWindow(window)
	return window
end


function defineFullScreen(self, menuItem)
	local group = RadioGroup()

	local fullscreen = self:getSettings()["fullscreen"]
	
	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
            {
                text = self:string("IMAGE_VIEWER_ZOOM_PICTURE"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setFullScreen(false)
                    end,
                    fullscreen == false
	            ),
            },
            {
                text = self:string("IMAGE_VIEWER_ZOOM_SCREEN"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setFullScreen(true)
                    end,
                    fullscreen == true
	            ),
            },           
		}))

	self:tieAndShowWindow(window)
	return window
end


function defineRotation(self, menuItem)
	local group = RadioGroup()

	local rotation = self:getSettings()["rotation"]
	
	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
            {
                text = self:string("IMAGE_VIEWER_ROTATION_YES"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setRotation("yes")
                    end,
                    rotation == "yes"
	            ),
            },
            {
                text = self:string("IMAGE_VIEWER_ROTATION_AUTO"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setRotation("auto")
                    end,
                    rotation == "auto"
	            ),
            },           
            {
                text = self:string("IMAGE_VIEWER_ROTATION_NO"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setRotation("no")
                    end,
                    rotation == "no"
	            ),
            },           
		}))

	self:tieAndShowWindow(window)
	return window
end

function defineTextInfo(self, menuItem)
	local group = RadioGroup()

	local textinfo = self:getSettings()["textinfo"]
	
	local window = Window("text_list", menuItem.text, 'settingstitle')
	window:addWidget(SimpleMenu("menu",
		{
            {
                text = self:string("IMAGE_VIEWER_TEXTINFO_YES"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTextInfo(true)
                    end,
                    textinfo == true
	            ),
            },
            {
                text = self:string("IMAGE_VIEWER_TEXTINFO_NO"),
		style = 'item_choice',
                check = RadioButton(
                    "radio",
                    group,
                    function()
                        self:setTextInfo(false)
                    end,
                    textinfo == false
	            ),
            },           
		}))

	self:tieAndShowWindow(window)
	return window
end


-- Configuration helpers

function setOrdering(self, ordering)
	self:getSettings()["ordering"] = ordering
	self:storeSettings()
end

function setDelay(self, delay)
	self:getSettings()["delay"] = delay
	self:storeSettings()
end


function setSource(self, source)
	self:getSettings()["source"] = source
	self:storeSettings()
end


function setTransition(self, transition)
	self:getSettings()["transition"] = transition
	self:storeSettings()
end


function setRotation(self, rotation)
	self:getSettings()["rotation"] = rotation
	self:storeSettings()
end


function setFullScreen(self, fullscreen)
	self:getSettings()["fullscreen"] = fullscreen
	self:storeSettings()
end

function setTextInfo(self, textinfo)
	self:getSettings()["textinfo"] = textinfo
	self:storeSettings()
end


-- Transitions

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

function getTransition(self)
	local transition
	local trans = self:getSettings()["transition"]
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
	elseif trans == "fade" then
		transition = Window.transitionFadeIn
	elseif trans == "pushleft" then
		transition = Window.transitionPushLeft
	elseif trans == "pushright" then
		transition = Window.transitionPushRight
	end	
	return transition
end


--[[

=head1 LICENSE

Copyright 2008 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]
