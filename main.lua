local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local GlobalRemotes = ReplicatedStorage:WaitForChild("Remotes")

local oldRuntime = PlayerGui:FindFirstChild("MushroomAutoTradeRuntime")
if oldRuntime then
	oldRuntime:Destroy()
end

local oldGui = PlayerGui:FindFirstChild("MushroomAutoTrade")
if oldGui then
	oldGui:Destroy()
end

local Runtime = Instance.new("Folder")
Runtime.Name = "MushroomAutoTradeRuntime"
Runtime.Parent = PlayerGui

local function alive()
	return Runtime.Parent == PlayerGui
end

local MODE = "SEND"

local MAX_PER_TRADE = 500000
local TRADE_COOLDOWN = 60
local REQUEST_TIMEOUT = 60
local TRADE_ACTIVE_TIMEOUT = 120

local RECEIVER_ACCEPT_DELAY = 4
local ACCEPT_INTERVAL = 0.5

local ADD_RETRY_COUNT = 5
local ADD_RETRY_INTERVAL = 0.35

local CANCEL_SETTLE_TIME = 3
local CANCEL_RETRY_DELAY = 1

local running = false
local cancelRequested = false
local autoAcceptEnabled = false

local activeTradeRemote = nil
local activeTradeTargetName = nil
local currentTradeCancelled = false

local incomingSenderName = nil

local receiveTradeStarted = {}
local receiveLastAccept = {}
local receiveCancelledRemote = {}

local MyRemotes = LocalPlayer:WaitForChild("Remotes")
local MyTradeRequestRemote =
	MyRemotes:WaitForChild("TradeRequestRemote")

local function getCoinsObject()
	local dataGui =
		PlayerGui:FindFirstChild("PlayerDataGui")
		or PlayerGui:WaitForChild(
			"PlayerDataGui",
			10
		)

	if not dataGui then
		return nil
	end

	local data =
		dataGui:FindFirstChild("Data")
		or dataGui:WaitForChild(
			"Data",
			10
		)

	if not data then
		return nil
	end

	return
		data:FindFirstChild("Coins")
		or data:WaitForChild(
			"Coins",
			10
		)
end

local Coins = getCoinsObject()

local function getBalance()
	if not Coins or not Coins.Parent then
		Coins = getCoinsObject()
	end

	if not Coins then
		return nil
	end

	return Coins.Value
end

local function formatNumber(value)
	value =
		math.floor(
			tonumber(value)
			or 0
		)

	local text = tostring(value)

	while true do
		local newText, count =
			text:gsub(
				"^(-?%d+)(%d%d%d)",
				"%1,%2"
			)

		text = newText

		if count == 0 then
			break
		end
	end

	return text
end

local function parseAmount(text)
	if not text then
		return nil
	end

	text =
		text:gsub(
			"[,%.%s]",
			""
		)

	return tonumber(text)
end

local function remoteMatches(
	remote,
	playerA,
	playerB
)
	if not remote:IsA("RemoteFunction") then
		return false
	end

	if
		not string.find(
			remote.Name,
			playerA,
			1,
			true
		)
	then
		return false
	end

	if
		not string.find(
			remote.Name,
			playerB,
			1,
			true
		)
	then
		return false
	end

	if
		not string.find(
			remote.Name,
			"TradeRemote",
			1,
			true
		)
	then
		return false
	end

	return true
end

local function findTradeRemote(
	playerA,
	playerB
)
	local name1 =
		playerA
		.. "-"
		.. playerB
		.. "TradeRemote"

	local name2 =
		playerB
		.. "-"
		.. playerA
		.. "TradeRemote"

	local remote =
		GlobalRemotes:FindFirstChild(name1)

	if
		remote
		and
		remote:IsA("RemoteFunction")
	then
		return remote
	end

	remote =
		GlobalRemotes:FindFirstChild(name2)

	if
		remote
		and
		remote:IsA("RemoteFunction")
	then
		return remote
	end

	for _, object in ipairs(
		GlobalRemotes:GetChildren()
	) do
		if
			remoteMatches(
				object,
				playerA,
				playerB
			)
		then
			return object
		end
	end

	return nil
end

local gui = Instance.new("ScreenGui")
gui.Name = "MushroomAutoTrade"
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 410, 0, 460)
main.Position = UDim2.new(0.5, -205, 0.5, -230)
main.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 38)
title.Position = UDim2.new(0, 10, 0, 5)
title.BackgroundTransparency = 1
title.Text = "ToolTradeCOS by Kien"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 20
title.Font = Enum.Font.GothamBold
title.Parent = main

local sendTabButton = Instance.new("TextButton")
sendTabButton.Size = UDim2.new(0.5, -8, 0, 36)
sendTabButton.Position = UDim2.new(0, 6, 0, 45)
sendTabButton.Text = "SEND"
sendTabButton.Font = Enum.Font.GothamBold
sendTabButton.TextSize = 14
sendTabButton.TextColor3 = Color3.fromRGB(255, 255, 255)
sendTabButton.BorderSizePixel = 0
sendTabButton.Parent = main

Instance.new("UICorner", sendTabButton)

local receiveTabButton = Instance.new("TextButton")
receiveTabButton.Size = UDim2.new(0.5, -8, 0, 36)
receiveTabButton.Position = UDim2.new(0.5, 2, 0, 45)
receiveTabButton.Text = "RECEIVE"
receiveTabButton.Font = Enum.Font.GothamBold
receiveTabButton.TextSize = 14
receiveTabButton.TextColor3 = Color3.fromRGB(255, 255, 255)
receiveTabButton.BorderSizePixel = 0
receiveTabButton.Parent = main

Instance.new("UICorner", receiveTabButton)

local balanceLabel = Instance.new("TextLabel")
balanceLabel.Size = UDim2.new(1, -20, 0, 30)
balanceLabel.Position = UDim2.new(0, 10, 0, 87)
balanceLabel.BackgroundTransparency = 1
balanceLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
balanceLabel.TextSize = 14
balanceLabel.Font = Enum.Font.Gotham
balanceLabel.Text = "Balance: ..."
balanceLabel.Parent = main

local sendPage = Instance.new("Frame")
sendPage.Size = UDim2.new(1, 0, 1, -120)
sendPage.Position = UDim2.new(0, 0, 0, 120)
sendPage.BackgroundTransparency = 1
sendPage.Parent = main

local receivePage = Instance.new("Frame")
receivePage.Size = UDim2.new(1, 0, 1, -120)
receivePage.Position = UDim2.new(0, 0, 0, 120)
receivePage.BackgroundTransparency = 1
receivePage.Visible = false
receivePage.Parent = main

local usernameBox = Instance.new("TextBox")
usernameBox.Size = UDim2.new(1, -20, 0, 42)
usernameBox.Position = UDim2.new(0, 10, 0, 10)
usernameBox.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
usernameBox.TextColor3 = Color3.fromRGB(255, 255, 255)
usernameBox.PlaceholderColor3 = Color3.fromRGB(150, 150, 150)
usernameBox.PlaceholderText = "Username khách"
usernameBox.Text = ""
usernameBox.ClearTextOnFocus = false
usernameBox.Font = Enum.Font.Gotham
usernameBox.TextSize = 15
usernameBox.Parent = sendPage

Instance.new("UICorner", usernameBox)

local amountBox = Instance.new("TextBox")
amountBox.Size = UDim2.new(1, -20, 0, 42)
amountBox.Position = UDim2.new(0, 10, 0, 62)
amountBox.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
amountBox.TextColor3 = Color3.fromRGB(255, 255, 255)
amountBox.PlaceholderColor3 = Color3.fromRGB(150, 150, 150)
amountBox.PlaceholderText = "Ví dụ: 1,000,000"
amountBox.Text = ""
amountBox.ClearTextOnFocus = false
amountBox.Font = Enum.Font.Gotham
amountBox.TextSize = 15
amountBox.Parent = sendPage

Instance.new("UICorner", amountBox)

local startButton = Instance.new("TextButton")
startButton.Size = UDim2.new(0.48, 0, 0, 42)
startButton.Position = UDim2.new(0, 10, 0, 116)
startButton.BackgroundColor3 = Color3.fromRGB(50, 110, 65)
startButton.Text = "START TRADE"
startButton.TextColor3 = Color3.fromRGB(255, 255, 255)
startButton.Font = Enum.Font.GothamBold
startButton.TextSize = 14
startButton.Parent = sendPage

Instance.new("UICorner", startButton)

local stopButton = Instance.new("TextButton")
stopButton.Size = UDim2.new(0.48, -10, 0, 42)
stopButton.Position = UDim2.new(0.52, 0, 0, 116)
stopButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
stopButton.Text = "STOP"
stopButton.TextColor3 = Color3.fromRGB(255, 255, 255)
stopButton.Font = Enum.Font.GothamBold
stopButton.TextSize = 14
stopButton.Parent = sendPage

Instance.new("UICorner", stopButton)

local sendStatus = Instance.new("TextLabel")
sendStatus.Size = UDim2.new(1, -20, 0, 115)
sendStatus.Position = UDim2.new(0, 10, 0, 172)
sendStatus.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
sendStatus.TextColor3 = Color3.fromRGB(230, 230, 230)
sendStatus.TextWrapped = true
sendStatus.TextXAlignment = Enum.TextXAlignment.Left
sendStatus.TextYAlignment = Enum.TextYAlignment.Top
sendStatus.Font = Enum.Font.Code
sendStatus.TextSize = 14
sendStatus.Text = "Ready"
sendStatus.Parent = sendPage

Instance.new("UICorner", sendStatus)

local receiveTitle = Instance.new("TextLabel")
receiveTitle.Size = UDim2.new(1, -20, 0, 35)
receiveTitle.Position = UDim2.new(0, 10, 0, 10)
receiveTitle.BackgroundTransparency = 1
receiveTitle.Text = "Receive Mode"
receiveTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
receiveTitle.Font = Enum.Font.GothamBold
receiveTitle.TextSize = 17
receiveTitle.Parent = receivePage

local receiveInfo = Instance.new("TextLabel")
receiveInfo.Size = UDim2.new(1, -20, 0, 45)
receiveInfo.Position = UDim2.new(0, 10, 0, 45)
receiveInfo.BackgroundTransparency = 1
receiveInfo.Text =
	"Receiver chỉ Accept Request + Accept Trade\nAddTradeItem bị khóa hoàn toàn"
receiveInfo.TextColor3 = Color3.fromRGB(200, 200, 200)
receiveInfo.Font = Enum.Font.Gotham
receiveInfo.TextSize = 13
receiveInfo.TextWrapped = true
receiveInfo.Parent = receivePage

local receiveAutoButton = Instance.new("TextButton")
receiveAutoButton.Size = UDim2.new(1, -20, 0, 45)
receiveAutoButton.Position = UDim2.new(0, 10, 0, 100)
receiveAutoButton.BackgroundColor3 = Color3.fromRGB(55, 55, 60)
receiveAutoButton.Text = "Auto Accept: OFF"
receiveAutoButton.TextColor3 = Color3.fromRGB(255, 255, 255)
receiveAutoButton.Font = Enum.Font.GothamBold
receiveAutoButton.TextSize = 14
receiveAutoButton.Parent = receivePage

Instance.new("UICorner", receiveAutoButton)

local receiveStatus = Instance.new("TextLabel")
receiveStatus.Size = UDim2.new(1, -20, 0, 125)
receiveStatus.Position = UDim2.new(0, 10, 0, 160)
receiveStatus.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
receiveStatus.TextColor3 = Color3.fromRGB(230, 230, 230)
receiveStatus.TextWrapped = true
receiveStatus.TextXAlignment = Enum.TextXAlignment.Left
receiveStatus.TextYAlignment = Enum.TextYAlignment.Top
receiveStatus.Font = Enum.Font.Code
receiveStatus.TextSize = 14
receiveStatus.Text = "Waiting..."
receiveStatus.Parent = receivePage

Instance.new("UICorner", receiveStatus)

local function updateBalance()
	local value = getBalance()

	if value ~= nil then
		balanceLabel.Text =
			"Balance: "
			.. formatNumber(value)
			.. " Mushroom"
	else
		balanceLabel.Text =
			"Balance: ERROR"
	end
end

updateBalance()

if Coins then
	Coins:GetPropertyChangedSignal("Value"):Connect(function()
		if alive() then
			updateBalance()
		end
	end)
end

local watchedObjects =
	setmetatable(
		{},
		{
			__mode = "k"
		}
	)

local function isCancelText(text)
	if type(text) ~= "string" then
		return false
	end

	local lower = string.lower(text)

	return
		string.find(
			lower,
			"cancelled the trade",
			1,
			true
		) ~= nil
		or
		string.find(
			lower,
			"canceled the trade",
			1,
			true
		) ~= nil
end

local function detectIncomingSender(text)
	if type(text) ~= "string" then
		return
	end

	local lower = string.lower(text)

	if
		not string.find(
			lower,
			"wants to trade with you",
			1,
			true
		)
	then
		return
	end

	for _, player in ipairs(
		Players:GetPlayers()
	) do
		if player ~= LocalPlayer then
			if
				string.find(
					lower,
					string.lower(player.Name),
					1,
					true
				)
			then
				incomingSenderName =
					player.Name

				return
			end
		end
	end
end

local function processTradeMessage(object)
	if not alive() then
		return
	end

	if
		not object:IsA("TextLabel")
		and
		not object:IsA("TextButton")
	then
		return
	end

	local text = object.Text

	detectIncomingSender(text)

	if not isCancelText(text) then
		return
	end

	if
		MODE == "SEND"
		and
		activeTradeRemote
	then
		currentTradeCancelled =
			true

		sendStatus.Text =
			"Customer cancelled trade"
			.. "\nChecking balance before retry..."
	end

	if
		MODE == "RECEIVE"
		and
		autoAcceptEnabled
	then
		for _, remote in ipairs(
			GlobalRemotes:GetChildren()
		) do
			if
				remote:IsA("RemoteFunction")
				and
				string.find(
					remote.Name,
					LocalPlayer.Name,
					1,
					true
				)
				and
				string.find(
					remote.Name,
					"TradeRemote",
					1,
					true
				)
			then
				receiveCancelledRemote[
					remote
				] =
					true
			end
		end

		receiveStatus.Text =
			"Trade cancelled"
			.. "\nWaiting for next request..."
	end
end

local function watchTextObject(object)
	if watchedObjects[object] then
		return
	end

	if
		not object:IsA("TextLabel")
		and
		not object:IsA("TextButton")
	then
		return
	end

	watchedObjects[object] = true

	object:GetPropertyChangedSignal(
		"Text"
	):Connect(function()
		if alive() then
			processTradeMessage(
				object
			)
		end
	end)

	object:GetPropertyChangedSignal(
		"Visible"
	):Connect(function()
		if
			alive()
			and
			object.Visible
		then
			processTradeMessage(
				object
			)
		end
	end)
end

for _, object in ipairs(
	PlayerGui:GetDescendants()
) do
	watchTextObject(object)
end

PlayerGui.DescendantAdded:Connect(
	function(object)
		if not alive() then
			return
		end

		watchTextObject(object)

		task.defer(function()
			if alive() then
				processTradeMessage(
					object
				)
			end
		end)
	end
)

local function setMode(newMode)
	if
		newMode ~= "SEND"
		and
		newMode ~= "RECEIVE"
	then
		return
	end

	if
		MODE == "SEND"
		and
		running
		and
		newMode == "RECEIVE"
	then
		cancelRequested = true
	end

	MODE = newMode

	if MODE == "SEND" then
		sendPage.Visible = true
		receivePage.Visible = false

		sendTabButton.BackgroundColor3 =
			Color3.fromRGB(
				60,
				110,
				70
			)

		receiveTabButton.BackgroundColor3 =
			Color3.fromRGB(
				45,
				45,
				50
			)

		autoAcceptEnabled = false

		receiveAutoButton.Text =
			"Auto Accept: OFF"

		receiveAutoButton.BackgroundColor3 =
			Color3.fromRGB(
				55,
				55,
				60
			)
	else
		sendPage.Visible = false
		receivePage.Visible = true

		sendTabButton.BackgroundColor3 =
			Color3.fromRGB(
				45,
				45,
				50
			)

		receiveTabButton.BackgroundColor3 =
			Color3.fromRGB(
				55,
				90,
				135
			)
	end
end

sendTabButton.MouseButton1Click:Connect(
	function()
		setMode("SEND")
	end
)

receiveTabButton.MouseButton1Click:Connect(
	function()
		setMode("RECEIVE")
	end
)

receiveAutoButton.MouseButton1Click:Connect(
	function()
		if MODE ~= "RECEIVE" then
			return
		end

		autoAcceptEnabled =
			not autoAcceptEnabled

		if autoAcceptEnabled then
			receiveAutoButton.Text =
				"Auto Accept: ON"

			receiveAutoButton.BackgroundColor3 =
				Color3.fromRGB(
					50,
					110,
					65
				)

			receiveStatus.Text =
				"Waiting for incoming trade..."
		else
			receiveAutoButton.Text =
				"Auto Accept: OFF"

			receiveAutoButton.BackgroundColor3 =
				Color3.fromRGB(
					55,
					55,
					60
				)

			receiveStatus.Text =
				"Auto Accept disabled"
		end
	end
)

setMode("SEND")

task.spawn(function()
	while alive() do
		if
			MODE == "RECEIVE"
			and
			autoAcceptEnabled
		then
			local sender = nil

			if incomingSenderName then
				sender =
					Players:FindFirstChild(
						incomingSenderName
					)
			end

			if sender then
				local existing =
					findTradeRemote(
						sender.Name,
						LocalPlayer.Name
					)

				if not existing then
					local remotes =
						sender:FindFirstChild(
							"Remotes"
						)

					if remotes then
						local requestRemote =
							remotes:FindFirstChild(
								"TradeRequestRemote"
							)

						if requestRemote then
							pcall(function()
								requestRemote:FireServer(
									"AcceptRequest"
								)
							end)
						end
					end
				end
			else
				for _, player in ipairs(
					Players:GetPlayers()
				) do
					if player ~= LocalPlayer then
						local existing =
							findTradeRemote(
								player.Name,
								LocalPlayer.Name
							)

						if not existing then
							local remotes =
								player:FindFirstChild(
									"Remotes"
								)

							if remotes then
								local requestRemote =
									remotes:FindFirstChild(
										"TradeRequestRemote"
									)

								if requestRemote then
									pcall(function()
										requestRemote:FireServer(
											"AcceptRequest"
										)
									end)
								end
							end
						end
					end
				end
			end
		end

		task.wait(0.25)
	end
end)

task.spawn(function()
	while alive() do
		if
			MODE == "RECEIVE"
			and
			autoAcceptEnabled
		then
			local now = os.clock()

			for _, remote in ipairs(
				GlobalRemotes:GetChildren()
			) do
				if
					remote:IsA(
						"RemoteFunction"
					)
					and
					string.find(
						remote.Name,
						LocalPlayer.Name,
						1,
						true
					)
					and
					string.find(
						remote.Name,
						"TradeRemote",
						1,
						true
					)
					and
					not receiveCancelledRemote[
						remote
					]
				then
					if
						not receiveTradeStarted[
							remote
						]
					then
						receiveTradeStarted[
							remote
						] =
							now

						receiveStatus.Text =
							"Trade detected"
							.. "\n"
							.. remote.Name
							.. "\nWaiting offer..."
					end

					local age =
						now
						-
						receiveTradeStarted[
							remote
						]

					local last =
						receiveLastAccept[
							remote
						]
						or 0

					if
						age
						>=
						RECEIVER_ACCEPT_DELAY
						and
						now - last
						>=
						ACCEPT_INTERVAL
					then
						receiveLastAccept[
							remote
						] =
							now

						receiveStatus.Text =
							"Trade active"
							.. "\nAuto AcceptTrade..."

						task.spawn(function()
							if
								MODE ~= "RECEIVE"
								or
								not autoAcceptEnabled
								or
								not alive()
								or
								not remote.Parent
								or
								receiveCancelledRemote[
									remote
								]
							then
								return
							end

							pcall(function()
								remote:InvokeServer(
									"AcceptTrade"
								)
							end)
						end)
					end
				end
			end
		end

		task.wait(0.1)
	end
end)

GlobalRemotes.ChildRemoved:Connect(
	function(remote)
		receiveTradeStarted[remote] =
			nil

		receiveLastAccept[remote] =
			nil

		receiveCancelledRemote[remote] =
			nil

		incomingSenderName = nil
	end
)

local function sendRequest(target)
	if MODE ~= "SEND" then
		return nil
	end

	local oldRemotes = {}

	for _, remote in ipairs(
		GlobalRemotes:GetChildren()
	) do
		if
			remoteMatches(
				remote,
				LocalPlayer.Name,
				target.Name
			)
		then
			oldRemotes[remote] =
				true
		end
	end

	local started = os.clock()
	local attempt = 0

	while
		os.clock() - started
		<
		REQUEST_TIMEOUT
	do
		if
			cancelRequested
			or
			not alive()
			or
			MODE ~= "SEND"
		then
			return nil
		end

		for _, remote in ipairs(
			GlobalRemotes:GetChildren()
		) do
			if
				remoteMatches(
					remote,
					LocalPlayer.Name,
					target.Name
				)
				and
				not oldRemotes[
					remote
				]
			then
				return remote
			end
		end

		attempt += 1

		sendStatus.Text =
			"Sending request..."
			.. "\nTarget: "
			.. target.Name
			.. "\nAttempt: "
			.. attempt

		pcall(function()
			MyTradeRequestRemote:FireServer(
				"SendRequest",
				target
			)
		end)

		local untilTime =
			os.clock() + 1

		while
			os.clock()
			<
			untilTime
		do
			if
				cancelRequested
				or
				not alive()
				or
				MODE ~= "SEND"
			then
				return nil
			end

			for _, remote in ipairs(
				GlobalRemotes:GetChildren()
			) do
				if
					remoteMatches(
						remote,
						LocalPlayer.Name,
						target.Name
					)
					and
					not oldRemotes[
						remote
					]
				then
					return remote
				end
			end

			task.wait(0.1)
		end
	end

	return nil
end

local function addMushroom(
	tradeRemote,
	amount
)
	if MODE ~= "SEND" then
		return false,
			"Receiver mode cannot add trade items"
	end

	for attempt = 1, ADD_RETRY_COUNT do
		if MODE ~= "SEND" then
			return false,
				"Receiver mode cannot add trade items"
		end

		if currentTradeCancelled then
			return false,
				"RETRY"
		end

		if
			cancelRequested
			or
			not alive()
		then
			return false,
				"STOP"
		end

		sendStatus.Text =
			"Adding Mushroom..."
			.. "\nAmount: "
			.. formatNumber(amount)
			.. "\nAttempt: "
			.. attempt

		local args = {
			"AddTradeItem",
			{
				Overwrite = true,
				ItemType = "Currency",
				Name = "Shooms",
				Amount = amount
			}
		}

		pcall(function()
			if MODE ~= "SEND" then
				return
			end

			tradeRemote:InvokeServer(
				unpack(args)
			)
		end)

		task.wait(
			ADD_RETRY_INTERVAL
		)
	end

	return true
end

local function clearActiveTrade(
	tradeRemote
)
	if activeTradeRemote == tradeRemote then
		activeTradeRemote = nil
		activeTradeTargetName = nil
		currentTradeCancelled = false
	end
end

local function evaluateBalance(
	before,
	amount
)
	local after = getBalance()

	if after == nil then
		return "FATAL",
			{
				message =
					"Không đọc được balance"
			}
	end

	if after == before then
		return "UNCHANGED",
			{
				before = before,
				after = after,
				amount = amount
			}
	end

	local actual =
		before - after

	if actual == amount then
		return "SUCCESS",
			{
				sent = actual,
				before = before,
				after = after
			}
	end

	return "FATAL",
		{
			message =
				"Balance thay đổi bất thường"
				.. "\nExpected: "
				.. formatNumber(amount)
				.. "\nActual: "
				.. formatNumber(actual)
				.. "\nĐã dừng để tránh trade dư."
		}
end

local function settleAfterCancel(
	before,
	amount
)
	local started =
		os.clock()

	while
		os.clock() - started
		<
		CANCEL_SETTLE_TIME
	do
		if
			cancelRequested
			or
			not alive()
			or
			MODE ~= "SEND"
		then
			return "FATAL",
				{
					message =
						"Stopped"
				}
		end

		local state, result =
			evaluateBalance(
				before,
				amount
			)

		if state == "SUCCESS" then
			return state, result
		end

		if state == "FATAL" then
			return state, result
		end

		sendStatus.Text =
			"Trade cancelled"
			.. "\nChecking balance..."
			.. "\nDo not resend yet"

		task.wait(0.2)
	end

	local state, result =
		evaluateBalance(
			before,
			amount
		)

	if state == "UNCHANGED" then
		return "RETRY",
			{
				before = before,
				amount = amount
			}
	end

	return state, result
end

local function keepSenderAccepted(
	tradeRemote,
	target,
	before,
	amount
)
	local started =
		os.clock()

	local remoteClosed = false

	local connection =
		GlobalRemotes.ChildRemoved:Connect(
			function(child)
				if child == tradeRemote then
					remoteClosed = true
				end
			end
		)

	while alive() do
		local balanceState,
			balanceResult =
			evaluateBalance(
				before,
				amount
			)

		if balanceState == "SUCCESS" then
			connection:Disconnect()

			clearActiveTrade(
				tradeRemote
			)

			return "SUCCESS",
				balanceResult
		end

		if balanceState == "FATAL" then
			connection:Disconnect()

			clearActiveTrade(
				tradeRemote
			)

			return "FATAL",
				balanceResult
		end

		if currentTradeCancelled then
			connection:Disconnect()

			local state, result =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return state, result
		end

		if
			remoteClosed
			or
			not tradeRemote.Parent
		then
			connection:Disconnect()

			local state, result =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return state, result
		end

		if
			cancelRequested
			or
			MODE ~= "SEND"
		then
			connection:Disconnect()

			clearActiveTrade(
				tradeRemote
			)

			return "FATAL",
				{
					message = "Stopped"
				}
		end

		if
			os.clock() - started
			>=
			TRADE_ACTIVE_TIMEOUT
		then
			pcall(function()
				tradeRemote:InvokeServer(
					"DeclineTrade"
				)
			end)

			connection:Disconnect()

			local state, result =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return state, result
		end

		sendStatus.Text =
			"Trade active"
			.. "\nAmount: "
			.. formatNumber(amount)
			.. "\nKeeping AcceptTrade..."

		pcall(function()
			tradeRemote:InvokeServer(
				"AcceptTrade"
			)
		end)

		task.wait(
			ACCEPT_INTERVAL
		)
	end

	connection:Disconnect()

	clearActiveTrade(
		tradeRemote
	)

	return "FATAL",
		{
			message =
				"Trade stopped"
		}
end

local function tradeOnce(
	target,
	amount
)
	if MODE ~= "SEND" then
		return "FATAL",
			{
				message =
					"Receiver mode cannot add trade items"
			}
	end

	local before =
		getBalance()

	if before == nil then
		return "FATAL",
			{
				message =
					"Không đọc được balance"
			}
	end

	if before < amount then
		return "FATAL",
			{
				message =
					"Không đủ Mushroom"
			}
	end

	local tradeRemote =
		sendRequest(target)

	if not tradeRemote then
		return "RETRY",
			{
				before = before,
				amount = amount
			}
	end

	activeTradeRemote =
		tradeRemote

	activeTradeTargetName =
		target.Name

	currentTradeCancelled =
		false

	sendStatus.Text =
		"Request accepted"
		.. "\nAdding: "
		.. formatNumber(amount)

	task.wait(0.4)

	local added,
		addResult =
		addMushroom(
			tradeRemote,
			amount
		)

	if not added then
		if addResult == "RETRY" then
			local state, result =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return state, result
		end

		clearActiveTrade(
			tradeRemote
		)

		return "FATAL",
			{
				message =
					tostring(addResult)
			}
	end

	if currentTradeCancelled then
		local state, result =
			settleAfterCancel(
				before,
				amount
			)

		clearActiveTrade(
			tradeRemote
		)

		return state, result
	end

	if MODE ~= "SEND" then
		clearActiveTrade(
			tradeRemote
		)

		return "FATAL",
			{
				message =
					"Receiver mode cannot add trade items"
			}
	end

	return
		keepSenderAccepted(
			tradeRemote,
			target,
			before,
			amount
		)
end

local function cooldown(
	seconds,
	remainingAmount
)
	for i = seconds, 1, -1 do
		if
			cancelRequested
			or
			not alive()
			or
			MODE ~= "SEND"
		then
			return false
		end

		sendStatus.Text =
			"Cooldown: "
			.. i
			.. "s"
			.. "\nRemaining: "
			.. formatNumber(
				remainingAmount
			)

		task.wait(1)
	end

	return true
end

local function startTrade()
	if MODE ~= "SEND" then
		return
	end

	if running then
		sendStatus.Text =
			"Trade đang chạy"
		return
	end

	cancelRequested = false

	local username =
		usernameBox.Text

	local total =
		parseAmount(
			amountBox.Text
		)

	if username == "" then
		sendStatus.Text =
			"Nhập username"
		return
	end

	if
		not total
		or
		total <= 0
	then
		sendStatus.Text =
			"Amount không hợp lệ"
		return
	end

	total =
		math.floor(total)

	local target =
		Players:FindFirstChild(
			username
		)

	if not target then
		sendStatus.Text =
			"Không tìm thấy player"
			.. "\n"
			.. username
		return
	end

	if target == LocalPlayer then
		sendStatus.Text =
			"Không thể trade chính mình"
		return
	end

	local startingBalance =
		getBalance()

	if startingBalance == nil then
		sendStatus.Text =
			"Không đọc được balance"
		return
	end

	if startingBalance < total then
		sendStatus.Text =
			"Không đủ Mushroom"
			.. "\nBalance: "
			.. formatNumber(
				startingBalance
			)
			.. "\nNeed: "
			.. formatNumber(total)

		return
	end

	running = true

	local remaining = total
	local totalSent = 0
	local completedTrades = 0
	local retryCount = 0

	while
		remaining > 0
		and
		not cancelRequested
		and
		alive()
		and
		MODE == "SEND"
	do
		local current =
			getBalance()

		if current == nil then
			sendStatus.Text =
				"TRADE STOPPED"
				.. "\nKhông đọc được balance"
			break
		end

		if current < remaining then
			sendStatus.Text =
				"TRADE STOPPED"
				.. "\nBalance hiện tại không đủ phần còn lại"
				.. "\nBalance: "
				.. formatNumber(current)
				.. "\nRemaining: "
				.. formatNumber(
					remaining
				)

			break
		end

		local amount =
			math.min(
				remaining,
				MAX_PER_TRADE,
				current
			)

		sendStatus.Text =
			"Preparing trade"
			.. "\nAmount: "
			.. formatNumber(amount)
			.. "\nRemaining: "
			.. formatNumber(
				remaining
			)

		local state,
			result =
			tradeOnce(
				target,
				amount
			)

		if state == "SUCCESS" then
			if
				not result
				or
				result.sent ~= amount
			then
				sendStatus.Text =
					"TRADE STOPPED"
					.. "\nVerification failed"

				break
			end

			totalSent +=
				result.sent

			remaining -=
				result.sent

			completedTrades += 1
			retryCount = 0

			updateBalance()

			if remaining <= 0 then
				sendStatus.Text =
					"DONE ✓"
					.. "\nCustomer: "
					.. target.Name
					.. "\nTotal sent: "
					.. formatNumber(
						totalSent
					)
					.. "\nBalance: "
					.. formatNumber(
						result.after
					)

				break
			end

			sendStatus.Text =
				"Trade #"
				.. completedTrades
				.. " DONE"
				.. "\nSent: "
				.. formatNumber(
					result.sent
				)
				.. "\nRemaining: "
				.. formatNumber(
					remaining
				)

			local continue =
				cooldown(
					TRADE_COOLDOWN,
					remaining
				)

			if not continue then
				break
			end

		elseif state == "RETRY" then
			retryCount += 1

			local balanceBeforeRetry =
				getBalance()

			if balanceBeforeRetry == nil then
				sendStatus.Text =
					"TRADE STOPPED"
					.. "\nKhông đọc được balance"

				break
			end

			if balanceBeforeRetry < remaining then
				sendStatus.Text =
					"TRADE STOPPED"
					.. "\nBalance không đủ để tiếp tục"
					.. "\nBalance: "
					.. formatNumber(
						balanceBeforeRetry
					)
					.. "\nRemaining: "
					.. formatNumber(
						remaining
					)

				break
			end

			sendStatus.Text =
				"Trade cancelled"
				.. "\nNo Mushroom deducted"
				.. "\nRetry same amount: "
				.. formatNumber(amount)
				.. "\nRetry #"
				.. retryCount

			task.wait(
				CANCEL_RETRY_DELAY
			)

		else
			local message =
				"Unknown error"

			if
				result
				and
				result.message
			then
				message =
					result.message
			end

			sendStatus.Text =
				"TRADE STOPPED"
				.. "\n"
				.. message

			break
		end
	end

	activeTradeRemote = nil
	activeTradeTargetName = nil
	currentTradeCancelled = false

	if cancelRequested then
		sendStatus.Text =
			"STOPPED"
			.. "\nSent: "
			.. formatNumber(
				totalSent
			)
			.. "\nRemaining: "
			.. formatNumber(
				remaining
			)
	end

	running = false
end

startButton.MouseButton1Click:Connect(
	function()
		if
			alive()
			and
			MODE == "SEND"
		then
			task.spawn(
				startTrade
			)
		end
	end
)

stopButton.MouseButton1Click:Connect(
	function()
		if alive() then
			cancelRequested = true

			sendStatus.Text =
				"Stopping..."
		end
	end
)
