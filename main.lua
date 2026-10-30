local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local GlobalRemotes = ReplicatedStorage:WaitForChild("Remotes")

local oldRuntime = PlayerGui:FindFirstChild("ToolTradeCOSRuntime")
if oldRuntime then
	oldRuntime:Destroy()
end

local oldGui = PlayerGui:FindFirstChild("ToolTradeCOS")
if oldGui then
	oldGui:Destroy()
end

local Runtime = Instance.new("Folder")
Runtime.Name = "ToolTradeCOSRuntime"
Runtime.Parent = PlayerGui

local function alive()
	return Runtime.Parent == PlayerGui
end

local MODE = "SEND"

local MAX_PER_TRADE = 500000
local TRADE_COOLDOWN = 60
local REQUEST_TIMEOUT = 60
local TRADE_ACTIVE_TIMEOUT = 120

local ACCEPT_INTERVAL = 0.5
local RECEIVER_ACCEPT_DELAY = 1

local ADD_RETRY_COUNT = 5
local ADD_RETRY_INTERVAL = 0.35

local CANCEL_SETTLE_TIME = 3
local CANCEL_RETRY_DELAY = 1

local running = false
local cancelRequested = false

local autoAcceptEnabled = false
local randomGiftEnabled = false

local inventoryPanelOpen = false
local blacklistOpen = false

local activeTradeRemote = nil
local activeTradeTargetName = nil
local currentTradeCancelled = false

local incomingSenderName = nil

local blacklist = {}
local inventoryCache = {}

local receiveStates = {}
local receiveCancelled = {}

local MyRemotes = LocalPlayer:WaitForChild("Remotes")
local MyTradeRequestRemote =
	MyRemotes:WaitForChild("TradeRequestRemote")

local function getCoinsObject()

	local dataGui =
		PlayerGui:FindFirstChild("PlayerDataGui")
		or
		PlayerGui:WaitForChild(
			"PlayerDataGui",
			10
		)

	if not dataGui then
		return nil
	end

	local data =
		dataGui:FindFirstChild("Data")
		or
		dataGui:WaitForChild(
			"Data",
			10
		)

	if not data then
		return nil
	end

	return
		data:FindFirstChild("Coins")
		or
		data:WaitForChild(
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

	local text =
		tostring(value)

	while true do

		local newText,
			count =
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

	if not string.find(
		remote.Name,
		playerA,
		1,
		true
	) then
		return false
	end

	if not string.find(
		remote.Name,
		playerB,
		1,
		true
	) then
		return false
	end

	if not string.find(
		remote.Name,
		"TradeRemote",
		1,
		true
	) then
		return false
	end

	return true
end

local function findTradeRemote(
	playerA,
	playerB
)

	for _, remote in ipairs(
		GlobalRemotes:GetChildren()
	) do

		if remoteMatches(
			remote,
			playerA,
			playerB
		) then

			return remote
		end
	end

	return nil
end

local function getInventoryFrame()

	local tradeGui =
		PlayerGui:FindFirstChild(
			"TradeHUDGui"
		)

	if not tradeGui then
		return nil
	end

	local bottom =
		tradeGui:FindFirstChild(
			"BottomFrame"
		)

	if not bottom then
		return nil
	end

	local creature =
		bottom:FindFirstChild(
			"CreatureInventoryFrame"
		)

	if not creature then
		return nil
	end

	local tabs =
		creature:FindFirstChild(
			"TabFrames"
		)

	if not tabs then
		return nil
	end

	local species =
		tabs:FindFirstChild(
			"Species"
		)

	if not species then
		return nil
	end

	return species:FindFirstChild(
		"ScrollingFrame"
	)
end

local function loadInventory()

	local scrolling =
		getInventoryFrame()

	if not scrolling then

		inventoryCache = {}

		return false
	end

	local result = {}

	for _, item in ipairs(
		scrolling:GetChildren()
	) do

		if
			item:IsA("ImageButton")
			or
			item:IsA("Frame")
		then

			local nameLabel =
				item:FindFirstChild(
					"NameLabel"
				)

			local amountLabel =
				item:FindFirstChild(
					"AmountLabel"
				)

			if
				nameLabel
				and
				nameLabel:IsA("TextLabel")
				and
				amountLabel
				and
				amountLabel:IsA("TextLabel")
			then

				local amount =
					tonumber(
						amountLabel.Text:match(
							"%d+"
						)
					)
					or 0

				if amount >= 1 then

					table.insert(
						result,
						{
							Name =
								nameLabel.Text,

							Amount =
								amount,

							Instance =
								item
						}
					)
				end
			end
		end
	end

	table.sort(
		result,
		function(a, b)

			return
				string.lower(a.Name)
				<
				string.lower(b.Name)
		end
	)

	inventoryCache = result

	return true
end

local function getUsableSpecies()

	local result = {}

	for _, species in ipairs(
		inventoryCache
	) do

		if
			species.Amount >= 1
			and
			not blacklist[
				species.Name
			]
		then

			table.insert(
				result,
				species
			)
		end
	end

	return result
end

local function getUsablePetCount()

	local total = 0

	for _, species in ipairs(
		getUsableSpecies()
	) do

		total += species.Amount
	end

	return total
end

local function getRandomSpecies()

	local usable =
		getUsableSpecies()

	local total = 0

	for _, species in ipairs(
		usable
	) do

		total += species.Amount
	end

	if total <= 0 then
		return nil
	end

	local roll =
		math.random(
			1,
			total
		)

	local current = 0

	for _, species in ipairs(
		usable
	) do

		current +=
			species.Amount

		if roll <= current then
			return species
		end
	end

	return usable[
		#usable
	]
end

local COLORS = {

	BG =
		Color3.fromRGB(
			28,
			28,
			32
		),

	CARD =
		Color3.fromRGB(
			42,
			42,
			48
		),

	INPUT =
		Color3.fromRGB(
			48,
			48,
			54
		),

	GREEN =
		Color3.fromRGB(
			49,
			122,
			73
		),

	GREEN_OFF =
		Color3.fromRGB(
			45,
			70,
			53
		),

	BLUE =
		Color3.fromRGB(
			57,
			96,
			138
		),

	BLUE_DARK =
		Color3.fromRGB(
			46,
			62,
			80
		),

	PURPLE =
		Color3.fromRGB(
			102,
			72,
			145
		),

	PURPLE_OFF =
		Color3.fromRGB(
			62,
			51,
			75
		),

	ORANGE =
		Color3.fromRGB(
			153,
			92,
			45
		),

	ORANGE_DARK =
		Color3.fromRGB(
			78,
			57,
			43
		),

	RED =
		Color3.fromRGB(
			137,
			57,
			57
		),

	TEXT =
		Color3.fromRGB(
			245,
			245,
			245
		),

	SUBTEXT =
		Color3.fromRGB(
			190,
			190,
			195
		)
}

local function addCorner(
	object,
	radius
)

	local corner =
		Instance.new(
			"UICorner"
		)

	corner.CornerRadius =
		UDim.new(
			0,
			radius or 7
		)

	corner.Parent =
		object
end

local function makeButton(
	parent,
	text,
	color
)

	local button =
		Instance.new(
			"TextButton"
		)

	button.BackgroundColor3 =
		color

	button.BorderSizePixel =
		0

	button.Text =
		text

	button.TextColor3 =
		COLORS.TEXT

	button.Font =
		Enum.Font.GothamBold

	button.TextSize =
		13

	button.AutoButtonColor =
		true

	button.Parent =
		parent

	addCorner(
		button,
		7
	)

	return button
end

local function makeLabel(
	parent,
	text
)

	local label =
		Instance.new(
			"TextLabel"
		)

	label.BackgroundTransparency =
		1

	label.Text =
		text

	label.TextColor3 =
		COLORS.TEXT

	label.Font =
		Enum.Font.Gotham

	label.TextSize =
		13

	label.Parent =
		parent

	return label
end

local gui =
	Instance.new(
		"ScreenGui"
	)

gui.Name =
	"ToolTradeCOS"

gui.ResetOnSpawn =
	false

gui.Parent =
	PlayerGui

local main =
	Instance.new(
		"Frame"
	)

main.Size =
	UDim2.new(
		0,
		430,
		0,
		410
	)

main.Position =
	UDim2.new(
		0.5,
		-215,
		0.5,
		-205
	)

main.BackgroundColor3 =
	COLORS.BG

main.BorderSizePixel =
	0

main.Active =
	true

main.Draggable =
	true

main.Parent =
	gui

addCorner(
	main,
	11
)

local title =
	makeLabel(
		main,
		"ToolTradeCOS by Kien"
	)

title.Size =
	UDim2.new(
		1,
		-20,
		0,
		36
	)

title.Position =
	UDim2.new(
		0,
		10,
		0,
		4
	)

title.Font =
	Enum.Font.GothamBold

title.TextSize =
	19

local sendTab =
	makeButton(
		main,
		"SEND",
		COLORS.GREEN
	)

sendTab.Size =
	UDim2.new(
		0.5,
		-8,
		0,
		36
	)

sendTab.Position =
	UDim2.new(
		0,
		6,
		0,
		44
	)

local receiveTab =
	makeButton(
		main,
		"RECEIVE",
		COLORS.CARD
	)

receiveTab.Size =
	UDim2.new(
		0.5,
		-8,
		0,
		36
	)

receiveTab.Position =
	UDim2.new(
		0.5,
		2,
		0,
		44
	)

local balanceLabel =
	makeLabel(
		main,
		"Balance: ..."
	)

balanceLabel.Size =
	UDim2.new(
		1,
		-20,
		0,
		27
	)

balanceLabel.Position =
	UDim2.new(
		0,
		10,
		0,
		84
	)

balanceLabel.TextColor3 =
	COLORS.SUBTEXT

local sendPage =
	Instance.new(
		"Frame"
	)

sendPage.Size =
	UDim2.new(
		1,
		0,
		1,
		-115
	)

sendPage.Position =
	UDim2.new(
		0,
		0,
		0,
		115
	)

sendPage.BackgroundTransparency =
	1

sendPage.Parent =
	main

local receivePage =
	Instance.new(
		"Frame"
	)

receivePage.Size =
	UDim2.new(
		1,
		0,
		1,
		-115
	)

receivePage.Position =
	UDim2.new(
		0,
		0,
		0,
		115
	)

receivePage.BackgroundTransparency =
	1

receivePage.Visible =
	false

receivePage.Parent =
	main

local usernameBox =
	Instance.new(
		"TextBox"
	)

usernameBox.Size =
	UDim2.new(
		1,
		-20,
		0,
		42
	)

usernameBox.Position =
	UDim2.new(
		0,
		10,
		0,
		0
	)

usernameBox.BackgroundColor3 =
	COLORS.INPUT

usernameBox.BorderSizePixel =
	0

usernameBox.Text =
	""

usernameBox.PlaceholderText =
	"Username khách"

usernameBox.PlaceholderColor3 =
	Color3.fromRGB(
		145,
		145,
		150
	)

usernameBox.TextColor3 =
	COLORS.TEXT

usernameBox.Font =
	Enum.Font.Gotham

usernameBox.TextSize =
	14

usernameBox.ClearTextOnFocus =
	false

usernameBox.Parent =
	sendPage

addCorner(
	usernameBox,
	7
)

local amountBox =
	Instance.new(
		"TextBox"
	)

amountBox.Size =
	UDim2.new(
		1,
		-20,
		0,
		42
	)

amountBox.Position =
	UDim2.new(
		0,
		10,
		0,
		52
	)

amountBox.BackgroundColor3 =
	COLORS.INPUT

amountBox.BorderSizePixel =
	0

amountBox.Text =
	""

amountBox.PlaceholderText =
	"Ví dụ: 1,000,000"

amountBox.PlaceholderColor3 =
	Color3.fromRGB(
		145,
		145,
		150
	)

amountBox.TextColor3 =
	COLORS.TEXT

amountBox.Font =
	Enum.Font.Gotham

amountBox.TextSize =
	14

amountBox.ClearTextOnFocus =
	false

amountBox.Parent =
	sendPage

addCorner(
	amountBox,
	7
)

local startButton =
	makeButton(
		sendPage,
		"START TRADE",
		COLORS.GREEN
	)

startButton.Size =
	UDim2.new(
		0.5,
		-15,
		0,
		42
	)

startButton.Position =
	UDim2.new(
		0,
		10,
		0,
		106
	)

local stopButton =
	makeButton(
		sendPage,
		"STOP",
		COLORS.RED
	)

stopButton.Size =
	UDim2.new(
		0.5,
		-15,
		0,
		42
	)

stopButton.Position =
	UDim2.new(
		0.5,
		5,
		0,
		106
	)

local sendStatus =
	makeLabel(
		sendPage,
		"Ready"
	)

sendStatus.Size =
	UDim2.new(
		1,
		-20,
		0,
		105
	)

sendStatus.Position =
	UDim2.new(
		0,
		10,
		0,
		160
	)

sendStatus.BackgroundTransparency =
	0

sendStatus.BackgroundColor3 =
	Color3.fromRGB(
		36,
		36,
		41
	)

sendStatus.TextXAlignment =
	Enum.TextXAlignment.Left

sendStatus.TextYAlignment =
	Enum.TextYAlignment.Top

sendStatus.TextWrapped =
	true

sendStatus.Font =
	Enum.Font.Code

sendStatus.TextSize =
	13

addCorner(
	sendStatus,
	7
)

local receiveAutoButton =
	makeButton(
		receivePage,
		"○  Auto Accept: OFF",
		COLORS.GREEN_OFF
	)

receiveAutoButton.Size =
	UDim2.new(
		1,
		-20,
		0,
		40
	)

receiveAutoButton.Position =
	UDim2.new(
		0,
		10,
		0,
		0
	)

local inventoryOptionsButton =
	makeButton(
		receivePage,
		"▶  INVENTORY OPTIONS",
		COLORS.BLUE_DARK
	)

inventoryOptionsButton.Size =
	UDim2.new(
		1,
		-20,
		0,
		38
	)

inventoryOptionsButton.Position =
	UDim2.new(
		0,
		10,
		0,
		50
	)

local inventoryPanel =
	Instance.new(
		"Frame"
	)

inventoryPanel.Size =
	UDim2.new(
		1,
		-20,
		0,
		155
	)

inventoryPanel.Position =
	UDim2.new(
		0,
		10,
		0,
		98
	)

inventoryPanel.BackgroundColor3 =
	Color3.fromRGB(
		34,
		34,
		39
	)

inventoryPanel.BorderSizePixel =
	0

inventoryPanel.Visible =
	false

inventoryPanel.Parent =
	receivePage

addCorner(
	inventoryPanel,
	8
)

local refreshButton =
	makeButton(
		inventoryPanel,
		"↻  Refresh Inventory",
		COLORS.BLUE
	)

refreshButton.Size =
	UDim2.new(
		1,
		-12,
		0,
		32
	)

refreshButton.Position =
	UDim2.new(
		0,
		6,
		0,
		6
	)

local randomToggle =
	makeButton(
		inventoryPanel,
		"Random Gift Species: OFF",
		COLORS.PURPLE_OFF
	)

randomToggle.Size =
	UDim2.new(
		1,
		-12,
		0,
		32
	)

randomToggle.Position =
	UDim2.new(
		0,
		6,
		0,
		44
	)

local blacklistButton =
	makeButton(
		inventoryPanel,
		"▶  Blacklist",
		COLORS.ORANGE_DARK
	)

blacklistButton.Size =
	UDim2.new(
		1,
		-12,
		0,
		32
	)

blacklistButton.Position =
	UDim2.new(
		0,
		6,
		0,
		82
	)

local blacklistFrame =
	Instance.new(
		"ScrollingFrame"
	)

blacklistFrame.Size =
	UDim2.new(
		1,
		-12,
		0,
		88
	)

blacklistFrame.Position =
	UDim2.new(
		0,
		6,
		0,
		120
	)

blacklistFrame.BackgroundColor3 =
	Color3.fromRGB(
		30,
		30,
		35
	)

blacklistFrame.BorderSizePixel =
	0

blacklistFrame.ScrollBarThickness =
	4

blacklistFrame.ScrollBarImageColor3 =
	COLORS.ORANGE

blacklistFrame.Visible =
	false

blacklistFrame.Parent =
	inventoryPanel

addCorner(
	blacklistFrame,
	6
)

local blacklistGrid =
	Instance.new(
		"UIGridLayout"
	)

blacklistGrid.CellSize =
	UDim2.new(
		0.5,
		-7,
		0,
		28
	)

blacklistGrid.CellPadding =
	UDim2.new(
		0,
		4,
		0,
		4
	)

blacklistGrid.SortOrder =
	Enum.SortOrder.LayoutOrder

blacklistGrid.Parent =
	blacklistFrame

local inventoryInfo =
	makeLabel(
		inventoryPanel,
		"Inventory chưa load"
	)

inventoryInfo.Size =
	UDim2.new(
		1,
		-16,
		0,
		28
	)

inventoryInfo.Position =
	UDim2.new(
		0,
		8,
		0,
		119
	)

inventoryInfo.Font =
	Enum.Font.Code

inventoryInfo.TextSize =
	12

inventoryInfo.TextColor3 =
	COLORS.SUBTEXT

inventoryInfo.TextXAlignment =
	Enum.TextXAlignment.Left

local receiveStatus =
	makeLabel(
		receivePage,
		"Waiting..."
	)

receiveStatus.Size =
	UDim2.new(
		1,
		-20,
		0,
		75
	)

receiveStatus.Position =
	UDim2.new(
		0,
		10,
		0,
		98
	)

receiveStatus.BackgroundTransparency =
	0

receiveStatus.BackgroundColor3 =
	Color3.fromRGB(
		36,
		36,
		41
	)

receiveStatus.Font =
	Enum.Font.Code

receiveStatus.TextSize =
	12

receiveStatus.TextWrapped =
	true

receiveStatus.TextXAlignment =
	Enum.TextXAlignment.Left

receiveStatus.TextYAlignment =
	Enum.TextYAlignment.Top

addCorner(
	receiveStatus,
	7
)

local function applySendLayout()

	main.Size =
		UDim2.new(
			0,
			430,
			0,
			410
		)
end

local function applyReceiveLayout()

	local statusY

	if not inventoryPanelOpen then

		inventoryPanel.Visible =
			false

		statusY =
			98

		main.Size =
			UDim2.new(
				0,
				430,
				0,
				305
			)

	else

		inventoryPanel.Visible =
			true

		if blacklistOpen then

			inventoryPanel.Size =
				UDim2.new(
					1,
					-20,
					0,
					248
				)

			blacklistFrame.Visible =
				true

			inventoryInfo.Position =
				UDim2.new(
					0,
					8,
					0,
					214
				)

			statusY =
				356

			main.Size =
				UDim2.new(
					0,
					430,
					0,
					558
				)

		else

			inventoryPanel.Size =
				UDim2.new(
					1,
					-20,
					0,
					155
				)

			blacklistFrame.Visible =
				false

			inventoryInfo.Position =
				UDim2.new(
					0,
					8,
					0,
					119
				)

			statusY =
				263

			main.Size =
				UDim2.new(
					0,
					430,
					0,
					465
				)
		end
	end

	receiveStatus.Position =
		UDim2.new(
			0,
			10,
			0,
			statusY
		)
end

local function updateBalance()

	local value =
		getBalance()

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

local function rebuildBlacklist()

	for _, object in ipairs(
		blacklistFrame:GetChildren()
	) do

		if object ~= blacklistGrid then
			object:Destroy()
		end
	end

	for index, species in ipairs(
		inventoryCache
	) do

		local button =
			makeButton(
				blacklistFrame,
				"",
				COLORS.ORANGE_DARK
			)

		button.LayoutOrder =
			index

		button.Font =
			Enum.Font.Gotham

		button.TextSize =
			11

		button.TextXAlignment =
			Enum.TextXAlignment.Left

		local function updateButton()

			if blacklist[
				species.Name
			] then

				button.Text =
					"  ✕ "
					.. species.Name
					.. " x"
					.. species.Amount

				button.BackgroundColor3 =
					COLORS.RED

			else

				button.Text =
					"  ○ "
					.. species.Name
					.. " x"
					.. species.Amount

				button.BackgroundColor3 =
					COLORS.ORANGE_DARK
			end
		end

		updateButton()

		button.MouseButton1Click:Connect(
			function()

				blacklist[
					species.Name
				] =
					not blacklist[
						species.Name
					]

				updateButton()

				inventoryInfo.Text =
					"Species: "
					.. #inventoryCache
					.. "  |  Pets usable: "
					.. getUsablePetCount()
			end
		)

		button.Parent =
			blacklistFrame
	end

	local rows =
		math.ceil(
			#inventoryCache
			/
			2
		)

	blacklistFrame.CanvasSize =
		UDim2.new(
			0,
			0,
			0,
			rows * 32
		)
end

local function refreshInventory()

	local success =
		loadInventory()

	if not success then

		inventoryInfo.Text =
			"Inventory: ERROR"

		receiveStatus.Text =
			"Không tìm thấy Species inventory"

		return false
	end

	inventoryInfo.Text =
		"Species: "
		.. #inventoryCache
		.. "  |  Pets usable: "
		.. getUsablePetCount()

	rebuildBlacklist()

	return true
end

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

		cancelRequested =
			true
	end

	MODE =
		newMode

	if MODE == "SEND" then

		sendPage.Visible =
			true

		receivePage.Visible =
			false

		sendTab.BackgroundColor3 =
			COLORS.GREEN

		receiveTab.BackgroundColor3 =
			COLORS.CARD

		autoAcceptEnabled =
			false

		randomGiftEnabled =
			false

		receiveAutoButton.Text =
			"○  Auto Accept: OFF"

		receiveAutoButton.BackgroundColor3 =
			COLORS.GREEN_OFF

		randomToggle.Text =
			"Random Gift Species: OFF"

		randomToggle.BackgroundColor3 =
			COLORS.PURPLE_OFF

		applySendLayout()

	else

		sendPage.Visible =
			false

		receivePage.Visible =
			true

		sendTab.BackgroundColor3 =
			COLORS.CARD

		receiveTab.BackgroundColor3 =
			COLORS.BLUE

		refreshInventory()

		applyReceiveLayout()
	end
end

sendTab.MouseButton1Click:Connect(
	function()

		setMode(
			"SEND"
		)
	end
)

receiveTab.MouseButton1Click:Connect(
	function()

		setMode(
			"RECEIVE"
		)
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
				"●  Auto Accept: ON"

			receiveAutoButton.BackgroundColor3 =
				COLORS.GREEN

			receiveStatus.Text =
				"Waiting for incoming trade..."

		else

			receiveAutoButton.Text =
				"○  Auto Accept: OFF"

			receiveAutoButton.BackgroundColor3 =
				COLORS.GREEN_OFF

			randomGiftEnabled =
				false

			randomToggle.Text =
				"Random Gift Species: OFF"

			randomToggle.BackgroundColor3 =
				COLORS.PURPLE_OFF

			receiveStatus.Text =
				"Auto Accept disabled"
		end
	end
)

inventoryOptionsButton.MouseButton1Click:Connect(
	function()

		inventoryPanelOpen =
			not inventoryPanelOpen

		inventoryOptionsButton.Text =
			inventoryPanelOpen
			and
			"▼  INVENTORY OPTIONS"
			or
			"▶  INVENTORY OPTIONS"

		inventoryOptionsButton.BackgroundColor3 =
			inventoryPanelOpen
			and
			COLORS.BLUE
			or
			COLORS.BLUE_DARK

		if inventoryPanelOpen then
			refreshInventory()
		end

		applyReceiveLayout()
	end
)

refreshButton.MouseButton1Click:Connect(
	function()

		refreshInventory()
	end
)

randomToggle.MouseButton1Click:Connect(
	function()

		if not autoAcceptEnabled then

			receiveStatus.Text =
				"Auto Accept phải ON trước"

			return
		end

		randomGiftEnabled =
			not randomGiftEnabled

		if randomGiftEnabled then

			randomToggle.Text =
				"Random Gift Species: ON"

			randomToggle.BackgroundColor3 =
				COLORS.PURPLE

			refreshInventory()

		else

			randomToggle.Text =
				"Random Gift Species: OFF"

			randomToggle.BackgroundColor3 =
				COLORS.PURPLE_OFF
		end
	end
)

blacklistButton.MouseButton1Click:Connect(
	function()

		blacklistOpen =
			not blacklistOpen

		if blacklistOpen then

			blacklistButton.Text =
				"▼  Blacklist"

			blacklistButton.BackgroundColor3 =
				COLORS.ORANGE

			refreshInventory()

		else

			blacklistButton.Text =
				"▶  Blacklist"

			blacklistButton.BackgroundColor3 =
				COLORS.ORANGE_DARK
		end

		applyReceiveLayout()
	end
)

updateBalance()

if Coins then

	Coins:GetPropertyChangedSignal(
		"Value"
	):Connect(
		function()

			if alive() then
				updateBalance()
			end
		end
	)
end

setMode(
	"SEND"
)

local watchedObjects =
	setmetatable(
		{},
		{
			__mode =
				"k"
		}
	)

local function isCancelText(text)

	if type(text) ~= "string" then
		return false
	end

	local lower =
		string.lower(text)

	return
		string.find(
			lower,
			"cancelled the trade",
			1,
			true
		)
		~= nil

		or

		string.find(
			lower,
			"canceled the trade",
			1,
			true
		)
		~= nil
end

local function detectIncomingSender(text)

	if type(text) ~= "string" then
		return
	end

	local lower =
		string.lower(text)

	if not string.find(
		lower,
		"wants to trade with you",
		1,
		true
	) then
		return
	end

	for _, player in ipairs(
		Players:GetPlayers()
	) do

		if player ~= LocalPlayer then

			if string.find(
				lower,
				string.lower(
					player.Name
				),
				1,
				true
			) then

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

	local text =
		object.Text

	detectIncomingSender(
		text
	)

	if not isCancelText(
		text
	) then
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

		for remote, state in pairs(
			receiveStates
		) do

			if
				remote
				and
				remote.Parent
			then

				state.Cancelled =
					true

				receiveCancelled[
					remote
				] =
					true
			end
		end

		receiveStatus.Text =
			"Trade cancelled"
			.. "\nWaiting for next trade..."
	end
end

local function watchTextObject(object)

	if watchedObjects[
		object
	] then
		return
	end

	if
		not object:IsA("TextLabel")
		and
		not object:IsA("TextButton")
	then
		return
	end

	watchedObjects[
		object
	] =
		true

	object:GetPropertyChangedSignal(
		"Text"
	):Connect(
		function()

			if alive() then

				processTradeMessage(
					object
				)
			end
		end
	)
end

for _, object in ipairs(
	PlayerGui:GetDescendants()
) do

	watchTextObject(
		object
	)
end

PlayerGui.DescendantAdded:Connect(
	function(object)

		if not alive() then
			return
		end

		watchTextObject(
			object
		)

		task.defer(
			function()

				if alive() then

					processTradeMessage(
						object
					)
				end
			end
		)
	end
)

local function getSenderRequestRemote(
	sender
)

	if not sender then
		return nil
	end

	local remotes =
		sender:FindFirstChild(
			"Remotes"
		)

	if not remotes then
		return nil
	end

	return remotes:FindFirstChild(
		"TradeRequestRemote"
	)
end

task.spawn(
	function()

		while alive() do

			if
				MODE == "RECEIVE"
				and
				autoAcceptEnabled
			then

				local handled =
					false

				if incomingSenderName then

					local sender =
						Players:FindFirstChild(
							incomingSenderName
						)

					if sender then

						local existing =
							findTradeRemote(
								sender.Name,
								LocalPlayer.Name
							)

						if not existing then

							local remote =
								getSenderRequestRemote(
									sender
								)

							if remote then

								pcall(
									function()

										remote:FireServer(
											"AcceptRequest"
										)
									end
								)

								handled =
									true
							end
						end
					end
				end

				if not handled then

					for _, sender in ipairs(
						Players:GetPlayers()
					) do

						if sender ~= LocalPlayer then

							local existing =
								findTradeRemote(
									sender.Name,
									LocalPlayer.Name
								)

							if not existing then

								local remote =
									getSenderRequestRemote(
										sender
									)

								if remote then

									pcall(
										function()

											remote:FireServer(
												"AcceptRequest"
											)
										end
									)
								end
							end
						end
					end
				end
			end

			task.wait(
				0.25
			)
		end
	end
)

local function addReceiverSpecies(
	tradeRemote,
	speciesName
)

	if MODE ~= "RECEIVE" then
		return false,
			"Not RECEIVE mode"
	end

	if not autoAcceptEnabled then
		return false,
			"Auto Accept OFF"
	end

	if not randomGiftEnabled then
		return false,
			"Random Gift OFF"
	end

	if
		not tradeRemote
		or
		not tradeRemote.Parent
	then

		return false,
			"TradeRemote unavailable"
	end

	if
		type(speciesName)
		~= "string"
		or
		speciesName == ""
	then

		return false,
			"Invalid Species"
	end

	for attempt = 1, ADD_RETRY_COUNT do

		if
			MODE ~= "RECEIVE"
			or
			not autoAcceptEnabled
			or
			not randomGiftEnabled
		then

			return false,
				"Receive gift disabled"
		end

		if
			not tradeRemote.Parent
			or
			receiveCancelled[
				tradeRemote
			]
		then

			return false,
				"Trade closed"
		end

		local args = {
			"AddTradeItem",
			{
				Overwrite =
					true,

				ItemType =
					"Creatures",

				Name =
					speciesName,

				Amount =
					1
			}
		}

		local success,
			result =
			pcall(
				function()

					return
						tradeRemote:InvokeServer(
							unpack(
								args
							)
						)
				end
			)

		if success then

			task.wait(
				ADD_RETRY_INTERVAL
			)

			return true,
				result
		end

		task.wait(
			ADD_RETRY_INTERVAL
		)
	end

	return false,
		"AddTradeItem failed"
end

task.spawn(
	function()

		while alive() do

			if
				MODE == "RECEIVE"
				and
				autoAcceptEnabled
			then

				local now =
					os.clock()

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
					then

						local state =
							receiveStates[
								remote
							]

						if not state then

							state = {
								Started =
									now,

								GiftName =
									nil,

								GiftAdded =
									not randomGiftEnabled,

								GiftAttempted =
									false,

								LastAccept =
									0,

								Cancelled =
									false,

								NoPet =
									false
							}

							receiveStates[
								remote
							] =
								state
						end

						if
							randomGiftEnabled
							and
							not state.GiftAttempted
							and
							not state.Cancelled
						then

							state.GiftAttempted =
								true

							refreshInventory()

							local species =
								getRandomSpecies()

							if not species then

								state.NoPet =
									true

								state.GiftAdded =
									false

								receiveStatus.Text =
									"Hết pet để nhận hàng"
									.. "\nPets usable: 0"

							else

								state.GiftName =
									species.Name

								receiveStatus.Text =
									"Trade detected"
									.. "\nGift: "
									.. species.Name
									.. " x1"
									.. "\nAdding gift..."

								local success,
									errorMessage =
									addReceiverSpecies(
										remote,
										species.Name
									)

								if success then

									state.GiftAdded =
										true

									receiveStatus.Text =
										"Gift added: "
										.. species.Name
										.. " x1"
										.. "\nWaiting AcceptTrade..."

								else

									state.GiftAdded =
										false

									receiveStatus.Text =
										"Add gift failed"
										.. "\n"
										.. tostring(
											errorMessage
										)
								end
							end
						end

						if
							not randomGiftEnabled
						then

							state.GiftAdded =
								true
						end

						local age =
							now
							-
							state.Started

						if
							not state.Cancelled
							and
							not state.NoPet
							and
							state.GiftAdded
							and
							age
							>=
							RECEIVER_ACCEPT_DELAY
							and
							now
							-
							state.LastAccept
							>=
							ACCEPT_INTERVAL
						then

							state.LastAccept =
								now

							task.spawn(
								function()

									if
										MODE
										~=
										"RECEIVE"
										or
										not autoAcceptEnabled
										or
										not alive()
										or
										not remote.Parent
										or
										state.Cancelled
									then

										return
									end

									pcall(
										function()

											remote:InvokeServer(
												"AcceptTrade"
											)
										end
									)
								end
							)
						end
					end
				end
			end

			task.wait(
				0.1
			)
		end
	end
)

GlobalRemotes.ChildRemoved:Connect(
	function(remote)

		local state =
			receiveStates[
				remote
			]

		receiveStates[
			remote
		] =
			nil

		receiveCancelled[
			remote
		] =
			nil

		incomingSenderName =
			nil

		if
			state
			and
			state.GiftName
			and
			not state.Cancelled
		then

			for _, species in ipairs(
				inventoryCache
			) do

				if
					species.Name
					==
					state.GiftName
				then

					species.Amount =
						math.max(
							0,
							species.Amount
							-
							1
						)

					break
				end
			end
		end

		if
			MODE == "RECEIVE"
			and
			autoAcceptEnabled
		then

			receiveStatus.Text =
				"Trade finished"
				.. "\nRefreshing inventory..."

			task.delay(
				1,
				function()

					if
						alive()
						and
						MODE
						==
						"RECEIVE"
					then

						refreshInventory()

						receiveStatus.Text =
							"Waiting for incoming trade..."
					end
				end
			)
		end
	end
)

local function sendRequest(
	target
)

	if MODE ~= "SEND" then
		return nil
	end

	local oldRemotes = {}

	for _, remote in ipairs(
		GlobalRemotes:GetChildren()
	) do

		if remoteMatches(
			remote,
			LocalPlayer.Name,
			target.Name
		) then

			oldRemotes[
				remote
			] =
				true
		end
	end

	local started =
		os.clock()

	local attempt =
		0

	while
		os.clock()
		-
		started
		<
		REQUEST_TIMEOUT
	do

		if
			cancelRequested
			or
			not alive()
			or
			MODE
			~=
			"SEND"
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

		attempt +=
			1

		sendStatus.Text =
			"Sending request..."
			.. "\nTarget: "
			.. target.Name
			.. "\nAttempt: "
			.. attempt

		pcall(
			function()

				MyTradeRequestRemote:FireServer(
					"SendRequest",
					target
				)
			end
		)

		local untilTime =
			os.clock()
			+
			1

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
				MODE
				~=
				"SEND"
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

			task.wait(
				0.1
			)
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
			"Not SEND mode"
	end

	for attempt = 1, ADD_RETRY_COUNT do

		if MODE ~= "SEND" then

			return false,
				"Not SEND mode"
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
			.. formatNumber(
				amount
			)
			.. "\nAttempt: "
			.. attempt

		local args = {
			"AddTradeItem",
			{
				Overwrite =
					true,

				ItemType =
					"Currency",

				Name =
					"Shooms",

				Amount =
					amount
			}
		}

		pcall(
			function()

				if MODE ~= "SEND" then
					return
				end

				tradeRemote:InvokeServer(
					unpack(
						args
					)
				)
			end
		)

		task.wait(
			ADD_RETRY_INTERVAL
		)
	end

	return true
end

local function evaluateBalance(
	before,
	amount
)

	local after =
		getBalance()

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
				before =
					before,

				after =
					after
			}
	end

	local actual =
		before
		-
		after

	if actual == amount then

		return "SUCCESS",
			{
				sent =
					actual,

				before =
					before,

				after =
					after
			}
	end

	return "FATAL",
		{
			message =
				"Balance thay đổi bất thường"
				.. "\nExpected: "
				.. formatNumber(
					amount
				)
				.. "\nActual: "
				.. formatNumber(
					actual
				)
				.. "\nSTOP để tránh trade dư."
		}
end

local function settleAfterCancel(
	before,
	amount
)

	local started =
		os.clock()

	while
		os.clock()
		-
		started
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

		local state,
			result =
			evaluateBalance(
				before,
				amount
			)

		if state == "SUCCESS" then

			return state,
				result
		end

		if state == "FATAL" then

			return state,
				result
		end

		sendStatus.Text =
			"Trade cancelled"
			.. "\nChecking balance..."
			.. "\nDo not resend yet"

		task.wait(
			0.2
		)
	end

	local state,
		result =
		evaluateBalance(
			before,
			amount
		)

	if state == "UNCHANGED" then

		return "RETRY",
			{
				before =
					before,

				amount =
					amount
			}
	end

	return state,
		result
end

local function clearActiveTrade(
	tradeRemote
)

	if
		activeTradeRemote
		==
		tradeRemote
	then

		activeTradeRemote =
			nil

		activeTradeTargetName =
			nil

		currentTradeCancelled =
			false
	end
end

local function keepSenderAccepted(
	tradeRemote,
	before,
	amount
)

	local started =
		os.clock()

	local remoteClosed =
		false

	local lastAcceptCall =
		0

	local connection =
		GlobalRemotes.ChildRemoved:Connect(
			function(child)

				if child == tradeRemote then

					remoteClosed =
						true
				end
			end
		)

	while alive() do

		local state,
			result =
			evaluateBalance(
				before,
				amount
			)

		if state == "SUCCESS" then

			connection:Disconnect()

			clearActiveTrade(
				tradeRemote
			)

			return "SUCCESS",
				result
		end

		if state == "FATAL" then

			connection:Disconnect()

			clearActiveTrade(
				tradeRemote
			)

			return "FATAL",
				result
		end

		if currentTradeCancelled then

			connection:Disconnect()

			local retryState,
				retryResult =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return retryState,
				retryResult
		end

		if
			remoteClosed
			or
			not tradeRemote.Parent
		then

			connection:Disconnect()

			local retryState,
				retryResult =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return retryState,
				retryResult
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
					message =
						"Stopped"
				}
		end

		if
			os.clock()
			-
			started
			>=
			TRADE_ACTIVE_TIMEOUT
		then

			connection:Disconnect()

			local retryState,
				retryResult =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return retryState,
				retryResult
		end

		sendStatus.Text =
			"Trade active"
			.. "\nAmount: "
			.. formatNumber(
				amount
			)
			.. "\nChecking completion..."

		if
			os.clock()
			-
			lastAcceptCall
			>=
			ACCEPT_INTERVAL
		then

			lastAcceptCall =
				os.clock()

			task.spawn(
				function()

					if
						not alive()
						or
						MODE ~= "SEND"
						or
						cancelRequested
						or
						not tradeRemote.Parent
					then

						return
					end

					pcall(
						function()

							tradeRemote:InvokeServer(
								"AcceptTrade"
							)
						end
					)
				end
			)
		end

		task.wait(
			0.1
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
					"Not SEND mode"
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
		sendRequest(
			target
		)

	if not tradeRemote then

		return "RETRY",
			{
				before =
					before,

				amount =
					amount
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
		.. formatNumber(
			amount
		)

	task.wait(
		0.4
	)

	local added,
		addResult =
		addMushroom(
			tradeRemote,
			amount
		)

	if not added then

		if addResult == "RETRY" then

			local state,
				result =
				settleAfterCancel(
					before,
					amount
				)

			clearActiveTrade(
				tradeRemote
			)

			return state,
				result
		end

		clearActiveTrade(
			tradeRemote
		)

		return "FATAL",
			{
				message =
					tostring(
						addResult
					)
			}
	end

	return
		keepSenderAccepted(
			tradeRemote,
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

		task.wait(
			1
		)
	end

	return true
end

local function startTrade()

	if MODE ~= "SEND" then
		return
	end

	if running then

		sendStatus.Text =
			"Trade trước vẫn đang xử lý"
			.. "\nVui lòng chờ hoàn tất."

		return
	end

	cancelRequested =
		false

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
		math.floor(
			total
		)

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
			.. formatNumber(
				total
			)

		return
	end

	running =
		true

	local remaining =
		total

	local totalSent =
		0

	local completedTrades =
		0

	local retryCount =
		0

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
				.. "\nBalance không đủ phần còn lại"
				.. "\nBalance: "
				.. formatNumber(
					current
				)
				.. "\nRemaining: "
				.. formatNumber(
					remaining
				)

			break
		end

		local amount =
			math.min(
				remaining,
				MAX_PER_TRADE
			)

		sendStatus.Text =
			"Preparing trade"
			.. "\nAmount: "
			.. formatNumber(
				amount
			)
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
				result.sent
				~=
				amount
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

			completedTrades +=
				1

			retryCount =
				0

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

			retryCount +=
				1

			local checkBalance =
				getBalance()

			if checkBalance == nil then

				sendStatus.Text =
					"TRADE STOPPED"
					.. "\nKhông đọc được balance"

				break
			end

			if checkBalance < remaining then

				sendStatus.Text =
					"TRADE STOPPED"
					.. "\nBalance không đủ để retry"
					.. "\nBalance: "
					.. formatNumber(
						checkBalance
					)
					.. "\nRemaining: "
					.. formatNumber(
						remaining
					)

				break
			end

			sendStatus.Text =
				"Trade cancelled"
				.. "\nBalance unchanged"
				.. "\nRetry same amount: "
				.. formatNumber(
					amount
				)
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

	activeTradeRemote =
		nil

	activeTradeTargetName =
		nil

	currentTradeCancelled =
		false

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

	running =
		false
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

			cancelRequested =
				true

			sendStatus.Text =
				"Stopping..."
		end
	end
)
