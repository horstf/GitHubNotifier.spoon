--- === GitHubNotifier ===
---
--- Check your GitHub notification inbox periodically via the `gh` CLI and show
--- it in a menubar app.
---
--- The number is how many notifications are unread, and the GitHub mark is
--- solid while any are. An empty inbox fades the mark. It always stays in the
--- menu bar, so a quiet menu bar never looks like a crashed spoon.
---
--- This tracks unread rather than "anything still in the inbox" because the
--- REST API cannot see GitHub's "done" state: notifications?all=true keeps
--- returning notifications you have marked Done and cleared from the web
--- inbox, so a mark driven by that would never fade. See includeRead.
---
--- The dropdown lists each notification; clicking one opens it in your browser.
--- Pull request rows carry GitHub's own colours for the state of the pull
--- request -- green open, purple merged, red closed, grey draft -- refreshed
--- alongside the inbox on every cycle.

-- luacheck: globals hs

local obj = {}

-- Metadata
obj.name = 'GitHubNotifier'
obj.version = '2.0'
obj.author = 'Horst <horst@volta-ai.com>'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

-- project the notification payload down to the handful of fields we use, so we
-- are not parsing a megabyte of repository objects every refresh
local jqFilter = '[.[] | {unread, reason, title: .subject.title, ' ..
	'type: .subject.type, url: .subject.url, repo: .repository.full_name, ' ..
	'repoUrl: .repository.html_url, updated: .updated_at}]'

-- places to look for the gh binary when no path is configured
local ghCandidates = {
	'/opt/homebrew/bin/gh',
	'/usr/local/bin/gh',
	'/opt/local/bin/gh',
	'/usr/bin/gh',
}

-- The GitHub mark, kept as an SVG so it stays crisp at any menu bar size.
-- Solid means there is something in the inbox; the faded copy means it is
-- empty. Fading the finished image in one pass keeps the silhouette even.
local spoonPath = debug.getinfo(1, 'S').source:sub(2):match('(.*/)') or './'

local function withAlpha(base, alpha)
	local size = base:size()
	local c = hs.canvas.new({ x = 0, y = 0, w = size.w, h = size.h })
	c[1] = {
		type = 'image',
		image = base,
		frame = { x = 0, y = 0, w = size.w, h = size.h },
		imageAlpha = alpha,
	}
	local img = c:imageFromCanvas()
	c:delete()
	return img
end

local markImage = hs.image.imageFromPath(spoonPath .. 'github-mark.svg')

if not markImage then
	-- the spoon still works without its artwork; just say so and draw a blob
	print('GitHubNotifier: could not load github-mark.svg, falling back to a plain icon')
	local c = hs.canvas.new({ x = 0, y = 0, w = 16, h = 16 })
	c[1] = {
		type = 'circle',
		center = { x = 8, y = 8 },
		radius = 7,
		action = 'fill',
		fillColor = { white = 0 },
	}
	markImage = c:imageFromCanvas()
	c:delete()
end

local fullIcon = markImage
local emptyIcon = withAlpha(markImage, 0.5)

-- small markers for the dropdown rows. Filled means unread, as it always
-- has; a colour on top of that is the pull request's state.
local function createDot(filled, color)
	local s = 14
	local stroke = 1.6
	local c = hs.canvas.new({ x = 0, y = 0, w = s, h = s })
	c[1] = {
		type = 'circle',
		center = { x = s / 2, y = s / 2 },
		-- leave half the stroke inside the canvas so a hollow dot is not clipped
		radius = s / 2 - stroke / 2 - 1,
		action = filled and 'fill' or 'stroke',
		fillColor = color or { white = 0 },
		strokeColor = color or { white = 0, alpha = 0.5 },
		strokeWidth = stroke,
	}
	local img = c:imageFromCanvas()
	c:delete()
	-- a plain dot has to follow the menu's text colour, so it is a template;
	-- a state dot carries its colour itself, which templating would discard
	return color and img or img:template(true)
end

local unreadDot = createDot(true)
local readDot = createDot(false)

-- GitHub's own state colours, picked to stay legible on a light and a dark menu
local stateColors = {
	OPEN = { red = 0.18, green = 0.65, blue = 0.31 },
	MERGED = { red = 0.51, green = 0.31, blue = 0.87 },
	CLOSED = { red = 0.81, green = 0.13, blue = 0.18 },
	DRAFT = { red = 0.43, green = 0.47, blue = 0.51 },
}

local stateDots = {}
for state, color in pairs(stateColors) do
	stateDots[state] = { unread = createDot(true, color), read = createDot(false, color) }
end

-- current state
local notifications = {}
local fetchError = nil

-- shorten long titles so the dropdown stays readable
local function truncate(str, max)
	if #str <= max then
		return str
	end
	return str:sub(1, max - 1) .. '…'
end

local function unreadCount()
	local n = 0
	for _, notification in ipairs(notifications) do
		if notification.unread then
			n = n + 1
		end
	end
	return n
end

-- update the menu bar icon and count
local function updateMenu()
	if not obj.menu then
		return
	end

	if fetchError then
		obj.menu:returnToMenuBar()
		obj.menu:setIcon(emptyIcon, true):setTitle('?')
		return
	end

	if #notifications == 0 and obj.hideWhenEmpty then
		obj.menu:removeFromMenuBar()
		return
	end

	obj.menu:returnToMenuBar()

	-- the tray fills whenever anything is still in the inbox; the number only
	-- appears when some of it is unread
	local unread = unreadCount()
	local icon = #notifications > 0 and fullIcon or emptyIcon
	local title = unread > 0 and tostring(unread) or ''

	obj.menu:setIcon(icon, true):setTitle(title)
end

-- turn a notification's API subject URL into something a browser can open
local function notificationUrl(notification)
	local repoUrl = notification.repoUrl
	local id = notification.url and notification.url:match('([^/]+)$')

	if repoUrl and id then
		if notification.type == 'PullRequest' then
			return repoUrl .. '/pull/' .. id
		elseif notification.type == 'Issue' then
			return repoUrl .. '/issues/' .. id
		elseif notification.type == 'Commit' then
			return repoUrl .. '/commit/' .. id
		end
	end

	if repoUrl then
		if notification.type == 'Release' then
			return repoUrl .. '/releases'
		elseif notification.type == 'Discussion' then
			return repoUrl .. '/discussions'
		end
		return repoUrl
	end

	return 'https://github.com/notifications'
end

-- build dropdown menu items
local function buildMenu()
	local items = {}

	if fetchError then
		table.insert(items, { title = 'gh error: ' .. truncate(fetchError, 60), disabled = true })
	elseif #notifications == 0 then
		table.insert(items, { title = 'Inbox is empty', disabled = true })
	else
		for _, notification in ipairs(notifications) do
			local repo = notification.repo or '?'
			local title = repo .. ' — ' .. truncate(notification.title or '(untitled)', 55)
			-- a pull request whose state we know gets the coloured dot; anything
			-- else, including a pull request the state query could not see, keeps
			-- the plain one
			local dots = notification.state and stateDots[notification.state]
			local image
			if dots then
				image = notification.unread and dots.unread or dots.read
			else
				image = notification.unread and unreadDot or readDot
			end
			table.insert(items, {
				title = title,
				image = image,
				fn = function()
					hs.urlevent.openURL(notificationUrl(notification))
				end,
			})
		end
	end

	table.insert(items, { title = '-' })
	table.insert(items, {
		title = 'Mark all as read',
		disabled = unreadCount() == 0,
		fn = function() obj:markAllAsRead() end,
	})
	table.insert(items, { title = 'Refresh now', fn = function() obj:refresh() end })
	table.insert(items, {
		title = 'Open Inbox',
		fn = function()
			hs.urlevent.openURL('https://github.com/notifications')
		end,
	})

	return items
end

-- The notification payload says nothing about whether a pull request is open,
-- merged or closed, so the states come from a second query. One aliased field
-- per pull request keeps the whole inbox to a single GraphQL request.
local function pullRequestRef(notification)
	if notification.type ~= 'PullRequest' then
		return nil
	end

	local owner, name = tostring(notification.repo or ''):match('^([%w._-]+)/([%w._-]+)$')
	local number = tostring(notification.url or ''):match('/(%d+)$')

	if not (owner and name and number) then
		return nil
	end

	return owner, name, tonumber(number)
end

local function onStates(exitCode, stdOut, _)
	-- gh exits non-zero when any one alias fails, but it prints the response
	-- body before it does, so a pull request we cannot see costs us that state
	-- and nothing else. A failure here is not a fetchError: the inbox itself
	-- arrived fine, the rows just keep their plain dots.
	local ok, json = pcall(hs.json.decode, stdOut)
	if not ok or type(json) ~= 'table' or type(json.data) ~= 'table' then
		print('GitHubNotifier: could not read pull request states (gh exit ' ..
			tostring(exitCode) .. ')')
		return
	end

	for alias, notification in pairs(obj.stateTargets or {}) do
		local result = json.data[alias]
		local pr = type(result) == 'table' and result.pullRequest
		if type(pr) == 'table' then
			notification.state = pr.isDraft and 'DRAFT' or pr.state
		end
	end
end

local function fetchPullRequestStates()
	-- a state query is already in flight; let it finish and catch up next cycle
	if obj.stateTask and obj.stateTask:isRunning() then
		return
	end

	local fields = {}
	local targets = {}

	for _, notification in ipairs(notifications) do
		local owner, name, number = pullRequestRef(notification)
		if owner then
			local alias = 'p' .. tostring(#fields + 1)
			fields[#fields + 1] = string.format(
				'%s: repository(owner: "%s", name: "%s") ' ..
				'{ pullRequest(number: %d) { state isDraft } }',
				alias, owner, name, number)
			targets[alias] = notification
		end
	end

	if #fields == 0 then
		obj.stateTargets = nil
		return
	end

	obj.stateTargets = targets
	obj.stateTask = hs.task.new(obj.ghPath, onStates,
		{ 'api', 'graphql', '-f', 'query=query {' .. table.concat(fields, ' ') .. '}' })
	obj.stateTask:start()
end

-- handle the result of a `gh` invocation
local function onResult(exitCode, stdOut, stdErr)
	if exitCode ~= 0 then
		fetchError = (stdErr or ''):gsub('%s+$', '')
		if fetchError == '' then
			fetchError = 'gh exited with code ' .. tostring(exitCode)
		end
		print('GitHubNotifier: ' .. fetchError)
		updateMenu()
		return
	end

	local ok, json = pcall(hs.json.decode, stdOut)
	if not ok or type(json) ~= 'table' then
		fetchError = 'could not parse gh output'
		print('GitHubNotifier: ' .. fetchError)
		updateMenu()
		return
	end

	-- unread first, then most recently updated
	table.sort(json, function(a, b)
		if a.unread ~= b.unread then
			return a.unread == true
		end
		return tostring(a.updated) > tostring(b.updated)
	end)

	fetchError = nil
	notifications = json
	updateMenu()

	-- states go stale as pull requests get merged, so they are re-read every
	-- cycle rather than cached across refreshes
	fetchPullRequestStates()
end

--- GitHubNotifier:refresh()
--- Method
--- Fetch the inbox immediately
---
--- Parameters: none
---
--- Returns:
---  * self (allow chaining)
function obj:refresh()
	if not self.ghPath then
		fetchError = 'gh CLI not found'
		updateMenu()
		return self
	end

	-- a fetch is already in flight; let it finish
	if self.task and self.task:isRunning() then
		return self
	end

	-- all=true keeps notifications that have been read but not marked Done,
	-- which is what lets the mark stay solid after you have caught up. Note
	-- that GitHub's "read" and "done" are different things: marking a
	-- notification read leaves it in the inbox, only Done removes it.
	local endpoint = 'notifications?all=' .. tostring(self.includeRead) ..
		'&per_page=' .. tostring(self.limit)

	self.task = hs.task.new(self.ghPath, onResult, { 'api', endpoint, '--jq', jqFilter })
	self.task:start()

	return self
end

--- GitHubNotifier:markAllAsRead()
--- Method
--- Mark every notification in the inbox as read
---
--- This is GitHub's "read", not "done": the notifications stay in the web
--- inbox, they just stop being bold. With the default includeRead = false the
--- list empties out and the mark fades.
---
--- Parameters: none
---
--- Returns:
---  * self (allow chaining)
function obj:markAllAsRead()
	if not self.ghPath then
		fetchError = 'gh CLI not found'
		updateMenu()
		return self
	end

	-- a mark is already in flight; let it finish
	if self.markTask and self.markTask:isRunning() then
		return self
	end

	local function onMarked(exitCode, _, stdErr)
		if exitCode ~= 0 then
			fetchError = (stdErr or ''):gsub('%s+$', '')
			if fetchError == '' then
				fetchError = 'gh exited with code ' .. tostring(exitCode)
			end
			print('GitHubNotifier: ' .. fetchError)
			updateMenu()
			return
		end

		fetchError = nil

		-- GitHub applies this asynchronously: a refresh right now would race it
		-- and usually come back still unread, leaving the menu bar unchanged.
		-- So settle the state locally first, which is what the next fetch will
		-- report anyway, and the menu bar updates the moment you click.
		if obj.includeRead then
			for _, notification in ipairs(notifications) do
				notification.unread = false
			end
		else
			-- nothing unread left to fetch, so the list empties and the mark fades
			notifications = {}
		end
		updateMenu()

		-- then reconcile with GitHub once it has caught up. Retained on self
		-- because an unreferenced timer can be collected before it fires.
		obj.markRefreshTimer = hs.timer.doAfter(5, function() obj:refresh() end)
	end

	self.markTask = hs.task.new(self.ghPath, onMarked, { 'api', '--method', 'PUT', 'notifications' })
	self.markTask:start()

	return self
end

--- GitHubNotifier:start(config)
--- Method
--- Start the spoon
---
--- Parameters:
---  * config - An optional table containing config values:
---             interval:      Interval in seconds to refresh (default 120)
---             limit:         Maximum notifications to fetch (default 100)
---             ghPath:        Path to the gh binary (default: autodetected)
---             hideWhenEmpty: Remove the menubar item entirely when the inbox
---                            is empty (default false, i.e. show a faded mark)
---             includeRead:   Also count notifications you have already read
---                            (default false). Off by default because the REST
---                            API does not expose GitHub's "done" state:
---                            notifications?all=true keeps returning things you
---                            have marked Done and cleared from the web inbox,
---                            so the mark would never fade. Only turn this on
---                            if you want that stickiness.
---
--- Returns:
---  * self (allow chaining)
function obj:start(config)
	config = config or {}

	local interval = config.interval or 120
	self.limit = config.limit or 100
	self.hideWhenEmpty = config.hideWhenEmpty or false

	-- Default false. GitHub's REST API has no concept of "done": marking a
	-- notification Done removes it from the web inbox but it keeps coming back
	-- from notifications?all=true forever, so including read notifications
	-- would leave the mark solid with no way to clear it.
	self.includeRead = config.includeRead == true

	-- locate the gh binary
	self.ghPath = config.ghPath
	if not self.ghPath then
		for _, candidate in ipairs(ghCandidates) do
			if hs.fs.attributes(candidate, 'mode') == 'file' then
				self.ghPath = candidate
				break
			end
		end
	end

	if not self.ghPath then
		print('GitHubNotifier: gh CLI not found, set ghPath in config')
	end

	-- create menubar (or restore it)
	if self.menu then
		self.menu:returnToMenuBar()
	else
		self.menu = hs.menubar.new():setMenu(buildMenu)
	end

	updateMenu()

	-- set timer to fetch periodically
	self.timer = hs.timer.new(interval, function() obj:refresh() end)
	self.timer:start()

	-- fetch immediately, too
	self:refresh()

	return self
end

--- GitHubNotifier:stop()
--- Method
--- Stop the spoon
---
--- Parameters: none
---
--- Returns:
---  * self (allow chaining)
function obj:stop()
	if self.menu then
		self.menu:removeFromMenuBar()
	end

	if self.timer then
		self.timer:stop()
	end

	return self
end

return obj
