-- CONFIG: edit these values before executing. Enabled can also be changed live.
getgenv().BlockSpinFishingConfig = {
    Enabled = true,
    AutoPlay = true,
    AutoSkipTutorial = true,
    AutoSkipAvatar = true,
    AutoPlayTimeout = 300,
    AutoRecoverLoading = true,
    LoadingRetryAfter = 75,
    LoadingOverlayTimeout = 45,
    LoadingMaxRetries = 2,
    LoadingTryNewPlayerServers = true,
    StartupCheckInterval = 0.35,
    MovementStuckTime = 0.65,
    MovementNoProgressTime = 1.5,
    MovementMaxStepDown = 3,
    MovementLookAhead = 30,
    FootRoadDistance = 180,
    BootstrapWithStocker = true,
    StarterBaitAmount = 50,
    PrepareFullKitOnStart = true,
    ReuseExistingStartupKit = true,
    AutoRetryErrors = true,
    RetryDelay = 5,
    MaxRetryDelay = 30,
    StockerWorkTimeout = 45,
    StockerArrivalDistance = 2.2,
    StockerBlockedTime = 0.65,
    BankStockerPay = true,
    AutoRespawn = true,
    AntiKill = true,
    ProtectionHealthThreshold = 25,
    ProtectionHideDepth = 8,
    CombatClearDelay = 2,
    JoinLowPopulationOnStart = true,
    StartupMaxPlayers = 6,
    PreferredServerMaxPlayers = 3,
    AutoBuyBike = true,
    AutoBuyCarCrate = true,
    CarCrateReserve = 0,
    CarCrateRetryDelay = 60,
    BikePurchaseReserve = 100,
    AutoPickupDrops = true,
    LootRadius = 120,
    LootReserveSlots = 2,
    RecoverDeathDrops = true,
    DeathLootExpiry = 180,
    DepositThreshold = 200,
    BaitPerTrip = 50,
    BaitLowWater = 0,
    AllowPurchaseWithdrawals = true,
    AutoUpgradeRods = true,
    AutoLicense = true,
    ResumeAfterDeath = true,
    EnableDeepSea = true,
    FishFromLakeCenter = true,
    SkyFishing = true,
    SkyFishingHeight = 55,
    SkyTravelSpeed = 30,
    SprintWhileSwimming = true,
    DeepSeaAnchor = nil, -- Optional: Vector3.new(X, Y, Z)
    VehicleSpeed = 42,
    PreferOwnedCars = true,
    CarMinTripDistance = 8,
    CarNearbyDistance = 40,
    CarFinalWalkDistance = 50,
    VehicleCooldownMaxWait = 90,
    UndergroundVehicleTravel = false,
    UndergroundVehicleDepth = 12,
    UndergroundVehicleSpeed = 80,
    UndergroundVehicleAcceleration = 90,
    UndergroundVehicleBraking = 100,
    VehicleSurfaceDistance = 10,
    VehicleDiveDuration = 0.65,
    BikeTurnSpeed = 18,
    BikeAgentRadius = 2.3,
    BikeMaxReplans = 5,
    BikeFinalApproach = 6,
    ScooterMinTripDistance = 8,
    ScooterNearbyDistance = 14,
    ScooterCooldownWait = 10,
    ObstaclePollInterval = 0.05,
    VaultDuration = 0.65,
    ObstacleNoclip = false,
    AllowFootVault = false,
    AllowGroundJump = false,
    NoclipDuration = 0.25,
    NoclipMaxDistance = 8,
    AutoClosePurchases = true,
    ShowStatusUI = true,
    LogStatus = true,
    LogHistoryLimit = 200,
}
local Config = getgenv().BlockSpinFishingConfig
local logStarted,logHistory,logRecent=os.clock(),{},{}
local logConsole=type(getrenv)=="function" and getrenv() or {print=print,warn=warn}
local function logEvent(category,message,key,interval)
    message=tostring(message)
    local now=os.clock()
    key=key or category
    local previous=logRecent[key]
    if previous and ((interval and now-previous.Time<interval) or (previous.Message==message and now-previous.Time<2)) then return end
    logRecent[key]={Time=now,Message=message}
    local item={Time=now-logStarted,Category=category,Message=message}
    table.insert(logHistory,item)
    if #logHistory>math.clamp(Config.LogHistoryLimit,20,1000) then table.remove(logHistory,1) end
    if Config.LogStatus then
        local line=string.format("[AutoFishing][+%.1fs][%s] %s",item.Time,category,message)
        if category=="ERROR" or category=="WARN" then (logConsole.warn or warn)(line) else (logConsole.print or print)(line) end
    end
end

-- BlockSpin auto fishing, based on the live session observed on 2026-11-25.
-- Stop DIBU using its own toggle before enabling this script.
-- Uses the game's existing slider click handler and server-authoritative results.
-- Sells fish at capacity, deposits all cash >= 200, and follows fishing unlocks.
-- Withdraws only a purchase shortfall for unlocked rods and bait (user-authorized).

local env = getgenv()
if env.BlockSpinStartupChecker then
    env.BlockSpinStartupChecker.Cancelled=true
    if env.BlockSpinStartupChecker.TeleportConnection then env.BlockSpinStartupChecker.TeleportConnection:Disconnect() end
end
if env.BlockSpinAutoFishing then env.BlockSpinAutoFishing.Destroy() end
-- Run before game/module/slider initialization: auto-execute can arrive before UI
-- and its click connections exist. Keep checking as the game builds its screens.
local startup={Started=os.clock(),Clicks={},Cancelled=false,Completed=false}
env.BlockSpinStartupChecker=startup
startup.Logs=logHistory
-- BEGIN STATUS OVERLAY
-- Read-only status overlay: this file does not start, stop, or move the player.
do
    local uiEnv=getgenv()
    if uiEnv.BlockSpinStatusUI then uiEnv.BlockSpinStatusUI.Destroy() end
    local overlay={Closed=false}
    uiEnv.BlockSpinStatusUI=overlay
    function overlay.Destroy()
        overlay.Closed=true
        if overlay.Gui then overlay.Gui:Destroy() end
        if uiEnv.BlockSpinStatusUI==overlay then uiEnv.BlockSpinStatusUI=nil end
    end
    local function describe(api,startup)
        if not api then return "Loading script",startup and startup.Phase or "Waiting for initialization",false end
        local raw=tostring(api.Status or "Ready")
        local lower=raw:lower()
        if uiEnv.BlockSpinSkyLanding then return "Landing from Sky Fishing",raw,true end
        if not api.Running then
            local retry=math.max(0,math.ceil((api.NextRetryAt or 0)-os.clock()))
            if api.Config and api.Config.Enabled and api.NextRetryAt then
                return "Retrying in "..retry.."s",tostring(api.LastRetryReason or raw),true
            end
            return "Script stopped",raw,false
        end
        if lower:find("cooldown",1,true) then
            local nextSpawn=game:GetService("Players").LocalPlayer:GetAttribute("SpawnVehicleNext")
            if type(nextSpawn)=="number" then
                local remaining=math.max(0,math.ceil(nextSpawn-workspace:GetServerTimeNow()))
                return "Vehicle cooldown: "..remaining.."s",raw,true
            end
        end
        local rules={
            {"cooldown","Waiting for vehicle cooldown"},
            {"quick11","Heading to Stocker"},
            {"stock room","Collecting a stock box"},
            {"stocker equipment funds","Earning money at Stocker"},
            {"stocking shelf","Stocking shelves"},
            {"assigned shelf","Heading to assigned shelf"},
            {"stock","Working as Stocker"},
            {"withdrawing","Withdrawing purchase funds"},
            {"deposit","Depositing cash"},
            {"atm","Heading to ATM"},
            {"selling fish","Selling fish"},
            {"sell fish","Heading to sell fish"},
            {"fish buyer","Approaching fish buyer"},
            {"car crate","Heading to car crate"},
            {"dealership","At the car dealership"},
            {"buying","Buying fishing supplies"},
            {"hardware","Heading to hardware store"},
            {"despawning","Despawning distant vehicle"},
            {"spawning","Spawning vehicle"},
            {"using inventory","Boarding vehicle"},
            {"descending below ground","Descending below ground"},
            {"travelling below ground","Driving below ground"},
            {"surfacing","Surfacing near destination"},
            {"descending gradually","Landing from Sky Fishing"},
            {"ascending gradually","Ascending for Sky Fishing"},
            {"below water","Approaching fishing spot underwater"},
            {"swimming","Swimming to fishing spot or shore"},
            {"reeling","Reeling in fish"},
            {"waiting for a bite","Fishing - waiting for a bite"},
            {"casting","Casting fishing rod"},
            {"respawn","Waiting to respawn"},
            {"loading","Waiting for game to load"},
            {"entrance","Approaching shop entrance"},
            {"exit","Leaving shop"},
        }
        for _,rule in ipairs(rules) do
            if lower:find(rule[1],1,true) then return rule[2],raw,lower:find("cooldown",1,true)~=nil end
        end
        return "Script running",raw,false
    end
    task.spawn(function()
        local player=game:GetService("Players").LocalPlayer
        local parent=player:WaitForChild("PlayerGui",15)
        if not parent or overlay.Closed then return end
        local gui=Instance.new("ScreenGui")
        gui.Name="BlockSpinFishingStatus"
        gui.ResetOnSpawn=false
        gui.DisplayOrder=100
        gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
        overlay.Gui=gui
        local panel=Instance.new("Frame")
        panel.Name="Panel"
        panel.AnchorPoint=Vector2.new(.5,0)
        panel.Position=UDim2.new(.5,0,0,12)
        panel.Size=UDim2.fromOffset(340,118)
        panel.BackgroundColor3=Color3.fromRGB(20,25,34)
        panel.BackgroundTransparency=.08
        panel.BorderSizePixel=0
        panel.Parent=gui
        local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(0,10);corner.Parent=panel
        local border=Instance.new("UIStroke");border.Color=Color3.fromRGB(65,78,96);border.Transparency=.3;border.Parent=panel
        local dot=Instance.new("Frame")
        dot.Name="Indicator";dot.Size=UDim2.fromOffset(8,8);dot.Position=UDim2.fromOffset(14,17);dot.BorderSizePixel=0;dot.Parent=panel
        local round=Instance.new("UICorner");round.CornerRadius=UDim.new(1,0);round.Parent=dot
        local function label(name,y,height,size,color)
            local text=Instance.new("TextLabel")
            text.Name=name;text.Position=UDim2.fromOffset(14,y);text.Size=UDim2.new(1,-28,0,height)
            text.BackgroundTransparency=1;text.BorderSizePixel=0;text.Font=Enum.Font.GothamMedium
            text.TextSize=size;text.TextColor3=color;text.TextXAlignment=Enum.TextXAlignment.Left
            text.TextYAlignment=Enum.TextYAlignment.Center;text.TextWrapped=true;text.RichText=false;text.Parent=panel
            return text
        end
        local title=label("Title",9,22,12,Color3.fromRGB(164,180,201));title.Text="SCRIPT STATUS";title.Position=UDim2.fromOffset(30,9);title.Size=UDim2.new(1,-44,0,22)
        local state=label("State",36,30,18,Color3.fromRGB(239,245,255))
        local detail=label("Detail",74,32,11,Color3.fromRGB(164,180,201))
        detail.TextXAlignment=Enum.TextXAlignment.Left
        gui.Parent=parent
        while not overlay.Closed and gui.Parent and uiEnv.BlockSpinStatusUI==overlay do
            local api=uiEnv.BlockSpinAutoFishing
            local config=uiEnv.BlockSpinFishingConfig or {}
            gui.Enabled=config.ShowStatusUI~=false
            local phase,reason,waiting=describe(api,uiEnv.BlockSpinStartupChecker)
            if state.Text~=phase then state.Text=phase end
            if detail.Text~=reason then detail.Text=reason end
            dot.BackgroundColor3=waiting and Color3.fromRGB(255,188,73) or (api and api.Running and Color3.fromRGB(74,211,145) or Color3.fromRGB(147,160,179))
            task.wait(.25)
        end
    end)
end

-- END STATUS OVERLAY
logEvent("STARTUP","Script loaded; checking loading, Play and Skip")
task.spawn(function()
    local names={
        {"AvatarMenuSkipButton","AutoSkipAvatar","CharacterCreator"},
        {"SlideshowCloseButton","AutoSkipTutorial"},
        {"PlayButton","AutoPlay","SplashScreenGui"},
    }
    local teleport=game:GetService("TeleportService")
    local nativeData,dataRequested
    local loadingInstance,loadingSeen,slowSeen
    startup.LoadingRejoinAttempts=0
    local ok,teleportData=pcall(function()return teleport:GetLocalPlayerTeleportData()end)
    local incomingRetries=0
    local triedNewPlayerServer=false
    if ok and type(teleportData)=="table" then
        incomingRetries=math.max(tonumber(teleportData.loading_rejoins) or 0,tonumber(teleportData.blockspin_loading_retries) or 0)
        triedNewPlayerServer=teleportData.blockspin_tried_new_player_server==true
    end
    startup.IncomingLoadingRetries=incomingRetries
    startup.TeleportConnection=teleport.TeleportInitFailed:Connect(function(who,result,message,placeId)
        if who==game:GetService("Players").LocalPlayer and startup.LoadingRejoinPending
            and (not placeId or placeId==startup.LoadingTargetPlaceId) then
            startup.LoadingRejoinPending=false
            startup.LoadingError=tostring(result)..": "..tostring(message)
            startup.LoadingRetryAt=os.clock()+30
            if result==Enum.TeleportResult.IsTeleporting then
                startup.LoadingBusyCount=(startup.LoadingBusyCount or 0)+1
                if startup.LoadingBusyCount<=2 then
                    startup.LoadingRejoinAttempts=math.max(0,startup.LoadingRejoinAttempts-1)
                    if startup.LoadingTargetPlaceId==97556409405464 and game.PlaceId==104715542330896 then
                        triedNewPlayerServer=false
                    end
                    startup.Phase="Waiting for previous teleport to finish"
                end
            end
        end
    end)
    local function recoverLoading(p,gui)
        local loading=gui:FindFirstChild("LoadingScreen")
        if not loading then loadingInstance,loadingSeen,slowSeen=nil,nil,nil return false end
        if loading~=loadingInstance then
            loadingInstance,loadingSeen,slowSeen=loading,os.clock(),false
        end
        local modules=game:GetService("ReplicatedStorage"):FindFirstChild("Modules")
        local core=modules and modules:FindFirstChild("Core")
        local dataModule=core and core:FindFirstChild("Data")
        if dataModule and not dataRequested then
            dataRequested=true
            -- Core.Data is already used by the native loading screen. Do not
            -- initialize gameplay modules until native startup completes.
            task.spawn(function()
                local success,data=pcall(require,dataModule)
                if success then nativeData=data else startup.LoadingError=tostring(data) end
            end)
        end
        local connected=false
        if nativeData and nativeData.connected then
            local success,value=pcall(nativeData.connected.get)
            connected=success and value==true
        end
        startup.DataConnected=connected
        local label=loading:FindFirstChild("IntroStatus",true)
        startup.LoadingText=label and label.Text or "Loading"
        local retryButton=loading:FindFirstChild("IntroRejoinButton",true)
        if retryButton and retryButton.Visible and not slowSeen then
            loadingSeen=math.min(loadingSeen,os.clock()-Config.LoadingRetryAfter+3)
            slowSeen=true
        end
        local elapsed=os.clock()-loadingSeen
        startup.LoadingAge=elapsed
        if not Config.AutoRecoverLoading then return true end
        if p:GetAttribute("is_session_locked")==true then
            startup.Phase="Waiting for the account session lock"
            return true
        end
        if connected then
            startup.DataReadyAt=startup.DataReadyAt or os.clock()
            startup.Phase="Account data loaded; waiting for intro assets"
            if game:IsLoaded() and os.clock()-startup.DataReadyAt>=Config.LoadingOverlayTimeout then
                -- The native Play callback rejects any remaining LoadingScreen.
                -- Detach an obsolete overlay only after real account data arrives;
                -- its native animation can still finish using its existing reference.
                p:SetAttribute("loading_screen_revealing",true)
                loading.Parent=nil
                startup.LoadingBypassed=true
                startup.Phase="Recovered stale loading overlay"
                return false
            end
            return true
        end
        startup.DataReadyAt=nil
        startup.Phase="Waiting for account data"
        if elapsed<Config.LoadingRetryAfter or os.clock()<(startup.LoadingRetryAt or 0) then return true end
        local attempts=incomingRetries+startup.LoadingRejoinAttempts
        if attempts>=Config.LoadingMaxRetries then
            startup.Phase="Loading retry limit reached"
            startup.LoadingError="Account data did not load; automatic rejoin limit reached"
            return true
        end
        if p:GetAttribute("IsInCombat")==true or startup.LoadingRejoinPending then return true end
        startup.LoadingRejoinAttempts+=1
        startup.LoadingRejoinPending=true
        local targetPlace=game.PlaceId
        if Config.LoadingTryNewPlayerServers and game.PlaceId==104715542330896 and not triedNewPlayerServer then
            targetPlace=97556409405464
            triedNewPlayerServer=true
        end
        startup.LoadingTargetPlaceId=targetPlace
        startup.Phase=targetPlace~=game.PlaceId and "Trying new-player server loading" or "Recovering loading with rejoin"
        startup.LoadingRetryAt=os.clock()+30
        local success,errorText=pcall(function()
            teleport:Teleport(targetPlace,p,{
                loading_rejoins=attempts+1,
                blockspin_loading_retries=attempts+1,
                blockspin_tried_new_player_server=triedNewPlayerServer,
            })
        end)
        if not success then startup.LoadingRejoinPending=false startup.LoadingError=tostring(errorText) end
        local attempt=startup.LoadingRejoinAttempts
        task.delay(25,function()
            if not startup.Cancelled and startup.LoadingRejoinPending and startup.LoadingRejoinAttempts==attempt then
                startup.LoadingRejoinPending=false
                startup.LoadingError="Loading rejoin did not complete"
            end
        end)
        return true
    end

    local lastClick={}
    local input=game:GetService("VirtualInputManager")
    while not startup.Cancelled and os.clock()-startup.Started<Config.AutoPlayTimeout do
        local p=game:GetService("Players").LocalPlayer
        local gui=p and p:FindFirstChildOfClass("PlayerGui")
        if gui and Config.Enabled and not recoverLoading(p,gui) then
            for _,entry in ipairs(names) do
                local scope=gui
                if entry[3] then scope=gui:FindFirstChild(entry[3],true) end
                local button=scope and scope:FindFirstChild(entry[1],true)
                if Config[entry[2]] and button and button:IsA("GuiButton") and button.AbsoluteSize.X>0 and button.AbsoluteSize.Y>0 then
                    local shown=true
                    local cursor=button
                    while cursor and cursor~=gui do
                        if (cursor:IsA("GuiObject") and not cursor.Visible) or (cursor:IsA("ScreenGui") and not cursor.Enabled) then shown=false break end
                        cursor=cursor.Parent
                    end
                    if shown and os.clock()-(lastClick[entry[1]] or -math.huge)>1.25 then
                        local point=button.AbsolutePosition+button.AbsoluteSize/2
                        local ok=pcall(function()
                            input:SendMouseButtonEvent(point.X,point.Y,0,true,game,0)
                            input:SendMouseButtonEvent(point.X,point.Y,0,false,game,0)
                        end)
                        lastClick[entry[1]]=os.clock()
                        if ok then startup.Clicks[entry[1]]=(startup.Clicks[entry[1]] or 0)+1 end
                        break
                    end
                end
            end
        end
        if startup.Phase~=startup.LastLoggedPhase then
            startup.LastLoggedPhase=startup.Phase
            if startup.Phase then logEvent("STARTUP",startup.Phase,"startup-phase",0.5) end
        end
        if startup.LoadingError and startup.LoadingError~=startup.LastLoggedError then
            startup.LastLoggedError=startup.LoadingError
            logEvent("WARN",startup.LoadingError,"loading-error",1)
        end
        task.wait(Config.StartupCheckInterval)
    end
    if startup.TeleportConnection then startup.TeleportConnection:Disconnect() startup.TeleportConnection=nil end
end)
while not game:IsLoaded() and not startup.Cancelled and os.clock()-startup.Started<Config.AutoPlayTimeout do task.wait(0.2) end
if startup.Cancelled then return end
if not game:IsLoaded() then startup.Cancelled=true error("Game loading timed out: "..tostring(startup.LoadingError or startup.Phase)) end
assert(game.PlaceId==104715542330896 or game.PlaceId==97556409405464 or game.PlaceId==132247642420063, "This script is for the supported BlockSpin places")
assert(type(filtergc) == "function", "Executor must support filtergc")

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Pathfinding = game:GetService("PathfindingService")
local player = Players.LocalPlayer
while not player do Players:GetPropertyChangedSignal("LocalPlayer"):Wait() player=Players.LocalPlayer end
-- Let the native game initialize its modules and menu callbacks first. Requiring
-- Game modules during auto-execute must not race their normal initialization.
if Config.Enabled then
    local readySince
    while not startup.Cancelled do
        local gui=player:FindFirstChildOfClass("PlayerGui")
        local splash=gui and gui:FindFirstChild("SplashScreenGui")
        local creator=gui and gui:FindFirstChild("CharacterCreator")
        local hud=gui and gui:FindFirstChild("TopRightHud")
        local menuFinished=(splash and not splash.Enabled) or (not splash and hud and hud.Enabled)
        local c=player.Character
        local hum=c and c:FindFirstChildOfClass("Humanoid")
        local deathGui=gui and gui:FindFirstChild("DeathScreen")
        local deathVisible=deathGui and deathGui:IsA("ScreenGui") and deathGui.Enabled
        local deadCharacter=hum and (hum.Health<=0 or hum:GetAttribute("IsDead")==true)
        if deathVisible and deadCharacter and (not splash or not splash.Enabled) then menuFinished=true end
        if not gui or not gui:FindFirstChild("LoadingScreen") then startup.Phase="Waiting for native startup UI" end
        if menuFinished and (not creator or not creator.Enabled) and hum and (hum.Health>0 or deathVisible) then
            readySince=readySince or os.clock()
            if os.clock()-readySince>=1 then startup.Phase="Native UI ready" break end
        else readySince=nil end
        if os.clock()-startup.Started>Config.AutoPlayTimeout then
            startup.Cancelled=true
            error("Startup UI did not finish loading; check BlockSpinStartupChecker before rerunning")
        end
        task.wait(0.2)
    end
    if startup.Cancelled then return end
end
local modules = RS:WaitForChild("Modules")
local function loadModule(path)
    local object=modules
    for name in string.gmatch(path,"[^.]+") do object=object:WaitForChild(name) end
    return require(object)
end
local Net = loadModule("Core.Net")
local Data = loadModule("Core.Data")
local RodModule = loadModule("Game.ItemTypes.FishingRod")
local Slider = loadModule("Game.Minigames.SliderMinigame")
local Items = loadModule("Game.Inventory.ItemUtils")
local Skills = loadModule("Game.Skills.SkillsList")
local XP = loadModule("Game.Skills.XPFormula")
local FishBuyer = loadModule("Game.Fishing.FishBuyerShared")
local Collection = game:GetService("CollectionService")
local Unlocks = loadModule("Game.Skills.SkillsList.fishing")
local Sprint = loadModule("Game.Sprint")
local Splash = loadModule("Game.SplashScreen")
local Slideshow = loadModule("Game.UI.Slideshow")
local CharacterCreator = loadModule("Game.CharacterCreator.CharacterCreator")
local ShelfStocking = loadModule("Game.Jobs.ShelfStocking")
local JobApplication = loadModule("Game.Jobs.JobApplicationBeacon")
local DeathScreen = loadModule("Game.DeathScreen")
local click

local API = {
    Logs=logHistory,
    Running = false, Status = "Ready", Catches = 0, Config = Config,
    Spot = Vector3.new(205.97638, 254.93259, -819.11719),
    Water = Vector3.new(192.29074, 249.84375, -765.84711),
    LastError = nil,
    Deposited = 0, Withdrawn = 0, Sold = 0, Level = 1,
    LastWarning = nil, DismissedPrompts = 0,
}
env.BlockSpinAutoFishing = API
local destroyed, generation = false, 0
local connections = {}
local dataHooks = {}
local lastClick, pendingLevel, pendingAt = 0, nil, 0
local activeRod, ownedCast, sessionId = nil, false, nil
local driveCleanup
local previousDeath=env.BlockSpinDeathRecovery
if previousDeath and previousDeath.JobId==game.JobId and os.time()-previousDeath.Time<Config.DeathLootExpiry then
    API.DeathRecovery=previousDeath
end
local function watchDeath(c)
    task.spawn(function()
        local hum=c:WaitForChild("Humanoid",10)
        if not hum or destroyed then return end
        connections[#connections+1]=hum.Died:Connect(function()
            local root=c:FindFirstChild("HumanoidRootPart")
            if not root then return end
            local record={Position=root.Position,Time=os.time(),JobId=game.JobId}
            API.DeathRecovery=record
            env.BlockSpinDeathRecovery=record
        end)
    end)
end
connections[#connections+1]=player.CharacterAdded:Connect(watchDeath)
if player.Character then watchDeath(player.Character) end

-- Keep the normal Net API, including its shared sequence counters and game environment.
local netGet = setfenv(function(...) return Net.get(...) end, getfenv(Net.get))
local netSend = setfenv(function(...) return Net.send(...) end, getfenv(Net.send))

local function status(message)
    if API.Status~=message then logEvent(message:sub(1,6)=="Error:" and "ERROR" or "STATUS",message) end
    API.Status = message
end
API.GetLogs=function(limit)
    local result={}
    limit=math.clamp(tonumber(limit) or 30,1,#logHistory+1)
    for i=math.max(1,#logHistory-limit+1),#logHistory do result[#result+1]=logHistory[i] end
    return result
end
local lastPopupSweep,lastPopupButton,lastPopupClick=0,nil,0
local lastConfigCheck=0
local lastDiagnostics={}
local function visible(object)
    local cursor=object
    while cursor and cursor~=game do
        if cursor:IsA("GuiObject") and not cursor.Visible then return false end
        if cursor:IsA("ScreenGui") and not cursor.Enabled then return false end
        cursor=cursor.Parent
    end
    return object:IsA("GuiObject") and object.AbsoluteSize.X>0 and object.AbsoluteSize.Y>0
end
local function cancelPurchasePrompts()
    if not Config.AutoClosePurchases or destroyed then return end
    local core=game:GetService("CoreGui")
    local candidates={}
    local acceptedRoots={FoundationOverlay=true,PurchasePrompt=true,RobuxPurchase=true,RobloxPromptGui=true}
    for _,root in ipairs(core:GetChildren()) do
        if acceptedRoots[root.Name] then candidates[#candidates+1]=root end
    end
    local robloxGui=core:FindFirstChild("RobloxGui")
    if robloxGui then
        local prompt=robloxGui:FindFirstChild("PurchasePrompt")
        if prompt then candidates[#candidates+1]=prompt end
    end
    for _,root in ipairs(candidates) do
        local purchaseTitle
        for _,text in ipairs(root:QueryDescendants("TextLabel, TextButton")) do
            if visible(text) then
                local value=text.Text:lower()
                if value:find("buy robux",1,true) or value:find("buy item",1,true) or value:find("purchase",1,true) or value:find("شراء",1,true) then
                    purchaseTitle=text
                    break
                end
            end
        end
        if purchaseTitle then
            local header=purchaseTitle:FindFirstAncestor("ModalHeader")
            local chosen,rightmost
            for _,button in ipairs(root:QueryDescendants("ImageButton, TextButton")) do
                if visible(button) then
                    local name=button.Name:lower()
                    local text=button:IsA("TextButton") and button.Text:lower() or ""
                    local explicit=name:find("close",1,true) or name:find("cancel",1,true) or text=="cancel" or text=="close" or text=="إلغاء" or text=="اغلاق"
                    -- In Roblox's Foundation purchase sheet, the rightmost HEADER icon is X.
                    local headerClose=header and button:IsDescendantOf(header) and not text:find("buy",1,true) and not text:find("robux",1,true)
                    local backdrop=name=="backdrop" and button:FindFirstAncestor("UnifiedRobuxUpsellModal")~=nil
                    if explicit or headerClose or backdrop then
                        local right=button.AbsolutePosition.X+button.AbsoluteSize.X
                        if explicit then chosen=button rightmost=math.huge
                        elseif backdrop and not chosen then chosen,rightmost=button,-math.huge
                        elseif headerClose and (not rightmost or right>rightmost) then chosen,rightmost=button,right end
                    end
                end
            end
            if chosen and (chosen~=lastPopupButton or os.clock()-lastPopupClick>2) then
                lastPopupButton,lastPopupClick=chosen,os.clock()
                -- Only close/cancel controls are eligible; the Buy action is never invoked.
                local point=chosen.AbsolutePosition+chosen.AbsoluteSize/2
                if chosen.Name=="Backdrop" then
                    -- The backdrop center can overlap Buy; click outside the sheet instead.
                    point=Vector2.new(12,game:GetService("GuiService"):GetGuiInset().Y+80)
                end
                local titleText=purchaseTitle.Text
                local ok,popupError=pcall(function()
                    local input=game:GetService("VirtualInputManager")
                    input:SendMouseButtonEvent(point.X,point.Y,0,true,game,0)
                    input:SendMouseButtonEvent(point.X,point.Y,0,false,game,0)
                end)
                if ok then
                    task.delay(0.3,function()
                        if not destroyed and (not purchaseTitle.Parent or not visible(purchaseTitle)) then
                            API.DismissedPrompts+=1
                            API.LastDismissedPrompt=titleText
                        end
                    end)
                else
                    API.LastWarning="Purchase prompt could not be closed: "..tostring(popupError)
                end
            end
        end
    end
end
local function alive(token)
    return not destroyed and not API.ProtectionActive and API.Running and generation == token
end
local function pressGameButton(button)
    if not button or not button:IsA("GuiButton") or not visible(button) then return false end
    local signal=button.MouseButton1Click
    local listeners=getconnections(signal)
    if #listeners==0 then signal=button.Activated listeners=getconnections(signal) end
    local point=button.AbsolutePosition+button.AbsoluteSize/2
    local physical=pcall(function()
        local input=game:GetService("VirtualInputManager")
        input:SendMouseButtonEvent(point.X,point.Y,0,true,game,0)
        input:SendMouseButtonEvent(point.X,point.Y,0,false,game,0)
    end)
    if physical then return true end
    local fired=false
    for _,listener in ipairs(listeners) do
        if listener.Enabled~=false and type(listener.Function)=="function" then
            task.spawn(listener.Function)
            fired=true
        end
    end
    if not fired and type(firesignal)=="function" then
        local ok=pcall(firesignal,signal)
        return ok
    end
    return fired
end
local function enterGame(token)
    if not Config.AutoPlay then return true end
    local deadline=os.clock()+Config.AutoPlayTimeout
    local lastPlay,lastTutorial,lastAvatar=-math.huge,-math.huge,-math.huge
    local readySince
    while alive(token) do
        if not Config.AutoPlay then return true end
        local character=player.Character
        local humanoid=character and character:FindFirstChildOfClass("Humanoid")
        if not Splash.in_loading_screen.get() and not CharacterCreator.is_in_creator.get() and Data.connected.get() and humanoid and humanoid.Health>0 then
            readySince=readySince or os.clock()
            if os.clock()-readySince>=0.6 then
                API.AutoPlayCompleted=true
                startup.Completed=true
                return true
            end
        else
            readySince=nil
        end
        if os.clock()>deadline then
            API.Retry("Auto Play timed out waiting for the game/character to finish loading")
            return false
        end
        local playerGui=player:FindFirstChildOfClass("PlayerGui")
        if playerGui then
            if Config.AutoSkipTutorial and Slideshow.current_slideshow.get()=="Tutorial" then
                status("Closing the first-join tutorial")
                if os.clock()-lastTutorial>=1 then
                    local close=playerGui:FindFirstChild("SlideshowCloseButton",true)
                    if pressGameButton(close) then lastTutorial=os.clock() end
                end
            elseif CharacterCreator.is_in_creator.get() then
                status("Skipping the avatar startup screen")
                if Config.AutoSkipAvatar and os.clock()-lastAvatar>=1 then
                    local creator=playerGui:FindFirstChild("CharacterCreator")
                    local skip=creator and creator:FindFirstChild("AvatarMenuSkipButton",true)
                    if pressGameButton(skip) then
                        lastAvatar=os.clock()
                        API.AutoAvatarSkipAttempts=(API.AutoAvatarSkipAttempts or 0)+1
                    end
                end
            elseif Splash.in_loading_screen.get() then
                status("Waiting for Play / entering the game")
                local screen=playerGui:FindFirstChild("SplashScreenGui")
                if screen and screen.Enabled and os.clock()-lastPlay>=1.5 then
                    local button=screen:FindFirstChild("PlayButton",true)
                    if pressGameButton(button) then
                        lastPlay=os.clock()
                        API.AutoPlayAttempts=(API.AutoPlayAttempts or 0)+1
                    end
                end
            else
                status("Waiting for the character to spawn")
            end
        end
        task.wait(0.2)
    end
    return false
end
local lastRespawnCheck,lastRespawnPress=0,-math.huge
local function autoRespawn()
    if not Config.AutoRespawn or not API.Running or destroyed then return end
    if not DeathScreen.enabled or not DeathScreen.enabled.get() then return end
    if os.clock()-lastRespawnPress<2 then return end
    local gui=player:FindFirstChildOfClass("PlayerGui")
    local screen=gui and gui:FindFirstChild("DeathScreen")
    local button=screen and screen:FindFirstChild("RespawnButton",true)
    local label=button and button:FindFirstChild("TextLabel")
    -- The native screen changes its label after the server's respawn countdown.
    if not label or label.Text~="Respawn" then return end
    local currentCharacter=player.Character
    local hum=currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health>0 and hum:GetAttribute("IsDead")~=true then return end
    if button and visible(button) then
        lastRespawnPress=os.clock()
        API.RespawnRequested=true
        API.AutoRespawnAttempts=(API.AutoRespawnAttempts or 0)+1
        status("Respawning")
        -- Same request as the game's Respawn callback, without clicking through purchase overlays.
        netSend("death_screen_request_respawn")
    end
end
connections[#connections+1]=player.CharacterAdded:Connect(function()
    API.StartupKitReady=false
    if API.Running and API.AutoPlayCompleted then API.NeedsRespawnRecovery=true end
    if API.RespawnRequested then API.AutoRespawns=(API.AutoRespawns or 0)+1 end
    API.RespawnRequested=false
    API.StockerShelf=nil
    API.OnIsland=false
    API.ZoneSkill=nil
end)
local function character()
    local c = player.Character
    return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart")
end
local function validWorldPosition(p)
    return p.X==p.X and p.Y==p.Y and p.Z==p.Z
        and math.abs(p.X)<100000 and p.Y>-500 and p.Y<10000 and math.abs(p.Z)<100000
end
local function cancelOwnedCast()
    if ownedCast and activeRod and activeRod.Parent then
        pcall(netSend, "cancel_throw", activeRod)
    end
    ownedCast, sessionId = false, nil
end
API.Protection=(function()
    local p={State="Idle",HopState="Idle",Attempts=0,StartupChecked=false,BlockedServers={},Serial=0}
    local teleport=game:GetService("TeleportService")
    local http=game:GetService("HttpService")
    local savedParts,hiddenCharacter,surface,hideAt,groundY
    local clearedAt,lastPulse,lastAttempt=nil,0,-math.huge
    local cache,cacheAt={},-math.huge
    local function enabled()
        return not destroyed and Config.Enabled
    end
    local function combatClear()
        -- Nil is unknown: never assume that combat ended from a missing attribute.
        return player:GetAttribute("IsInCombat")==false
    end
    local function restore()
        if hiddenCharacter and player.Character==hiddenCharacter then
            local root=hiddenCharacter:FindFirstChild("HumanoidRootPart")
            if root and surface then
                hiddenCharacter:PivotTo(surface*root.CFrame:Inverse()*hiddenCharacter:GetPivot())
                root.AssemblyLinearVelocity=Vector3.zero
            end
            local h=hiddenCharacter:FindFirstChildOfClass("Humanoid")
            if h and h.Health>0 and h:GetAttribute("Stunned")~=true then h:ChangeState(Enum.HumanoidStateType.GettingUp) end
        end
        for part,value in pairs(savedParts or {}) do if part.Parent then part.CanCollide=value end end
        savedParts,hiddenCharacter,surface,hideAt,groundY=nil,nil,nil,nil,nil
        p.SurfacePosition=nil
        p.FullyHidden=false
        p.TrackedCharacter=nil
    end
    function p.Stop()
        p.Serial+=1
        p.Pending=false
        p.Searching=false
        restore()
        API.ProtectionActive=false
        p.State="Idle"
        p.HopState="Idle"
    end
    function p.FindServers()
        if #cache>0 and os.clock()-cacheAt<45 then return cache end
        local url="https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100"
        local finished,ok,body=false,false,nil
        task.spawn(function()
            ok,body=pcall(function()return game:HttpGet(url)end)
            finished=true
        end)
        local deadline=os.clock()+12
        while not finished and os.clock()<deadline do task.wait(0.1) end
        if not finished then p.RetryAfter=os.clock()+60 return nil,"Server list request timed out" end
        if not ok then p.RetryAfter=os.clock()+60 return nil,tostring(body) end
        if type(body)~="string" or body=="" then p.RetryAfter=os.clock()+60 return nil,"Empty or rate-limited server list response" end
        local ok,data=pcall(function()return http:JSONDecode(body)end)
        if not ok or type(data)~="table" or type(data.data)~="table" then p.RetryAfter=os.clock()+60 return nil,"Invalid or rate-limited server list response" end
        local servers={}
        for _,server in ipairs(data.data) do
            if type(server.id)=="string" and type(server.playing)=="number" and type(server.maxPlayers)=="number"
                and server.id~=game.JobId and server.playing<server.maxPlayers then
                table.insert(servers,{Id=server.id,Players=server.playing,MaxPlayers=server.maxPlayers,Ping=tonumber(server.ping) or math.huge})
            end
        end
        table.sort(servers,function(a,b)
            if a.Players~=b.Players then return a.Players<b.Players end
            return a.Ping<b.Ping
        end)
        cache,cacheAt=servers,os.clock()
        return servers
    end
    function p.SelectServer(servers,startupHop)
        for _,server in ipairs(servers) do
            if not p.BlockedServers[server.Id] and server.Id~=game.JobId and server.Players<server.MaxPlayers
                and (not startupHop or server.Players+1<#Players:GetPlayers()) then
                if not startupHop or server.Players+1<=Config.PreferredServerMaxPlayers then return server end
            end
        end
        -- If the preferred population is unavailable, still choose a smaller server.
        if startupHop then
            for _,server in ipairs(servers) do
                if not p.BlockedServers[server.Id] and server.Id~=game.JobId and server.Players+1<#Players:GetPlayers()
                    and server.Players<server.MaxPlayers then return server end
            end
        end
    end
    function p.Hop(reason,startupHop)
        if p.Pending or not enabled() or not combatClear() then return false end
        if os.clock()<(p.RetryAfter or 0) then p.HopState="Waiting for server list cooldown" return false end
        p.HopState="Finding low population server"
        local serial=p.Serial
        local servers,why=p.FindServers()
        if serial~=p.Serial or not enabled() or not combatClear() then return false end
        if not servers then p.LastError=why p.HopState="Server list unavailable" return false end
        local target=p.SelectServer(servers,startupHop)
        if not target then p.HopState="No suitable lower population server" return false end
        p.Target={Id=target.Id,Players=target.Players,ExpectedPlayers=target.Players+1,Reason=reason}
        p.Pending=true
        p.Attempts+=1
        p.HopState="Teleport requested"
        p.BlockedServers[target.Id]=true
        local ok,errorText=pcall(function()teleport:TeleportToPlaceInstance(game.PlaceId,target.Id,player)end)
        if not ok then p.Pending=false p.LastError=tostring(errorText) p.HopState="Teleport rejected" return false end
        task.delay(25,function()
            if serial==p.Serial and enabled() and p.Pending then
                p.Pending=false
                p.LastError="Teleport did not complete before timeout"
                p.HopState="Teleport timed out"
            end
        end)
        return true
    end
    connections[#connections+1]=teleport.TeleportInitFailed:Connect(function(who,result,message)
        if who==player and p.Pending then
            p.Pending=false
            p.LastError=tostring(result)..": "..tostring(message)
            p.HopState="Teleport initialization failed"
        end
    end)
    function p.BeforeStart(token)
        if p.StartupChecked or not Config.JoinLowPopulationOnStart then return true end
        p.StartupChecked=true
        if #Players:GetPlayers()<=Config.StartupMaxPlayers then p.HopState="Current server population acceptable" return true end
        status("Waiting for combat to end before startup server selection")
        while alive(token) and not combatClear() do task.wait(0.25) end
        if not alive(token) then return false end
        for attempt=1,3 do
            if not alive(token) then return false end
            status("Selecting a lower population server")
            local began=p.Hop("Startup population",true)
            if began then
                while alive(token) and p.Pending do task.wait(0.25) end
                if not alive(token) then return false end
            elseif p.HopState=="No suitable lower population server" then return true end
            if attempt<3 then
                local untilAt=os.clock()+math.max(2,(p.RetryAfter or 0)-os.clock())
                while alive(token) and os.clock()<untilAt do task.wait(0.25) end
            end
        end
        API.LastWarning="Could not switch servers: "..tostring(p.LastError or p.HopState)
        return true
    end
    local function bodyTop(c)
        local top=-math.huge
        for _,part in ipairs(c:QueryDescendants("BasePart")) do
            local frame,size=part.CFrame,part.Size
            local extent=(math.abs(frame.RightVector.Y)*size.X+math.abs(frame.UpVector.Y)*size.Y+math.abs(frame.LookVector.Y)*size.Z)/2
            top=math.max(top,part.Position.Y+extent)
        end
        return top
    end
    local function bindCharacter(c,h,root)
        if hiddenCharacter and hiddenCharacter~=c then restore() end
        surface=root.CFrame
        p.SurfacePosition=surface.Position
        hiddenCharacter=c
        p.TrackedCharacter=c
        savedParts={}
        for _,part in ipairs(c:QueryDescendants("BasePart")) do savedParts[part]=part.CanCollide end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances={c}
        params.RespectCanCollide=true
        params.IgnoreWater=true
        local floor=workspace:Raycast(root.Position,Vector3.new(0,-96,0),params)
        if not floor then floor=workspace:Raycast(root.Position+Vector3.new(0,12,0),Vector3.new(0,-128,0),params) end
        groundY=floor and floor.Position.Y or root.Position.Y
        local highestOffset=math.max(0,bodyTop(c)-root.Position.Y)
        local clearance=math.clamp(Config.ProtectionHideDepth,4,30)
        hideAt=Vector3.new(root.Position.X,groundY-clearance-highestOffset,root.Position.Z)
        p.HideGroundY=groundY
    end
    local function activate(c,h,root)
        p.Serial+=1
        API.ProtectionActive=true
        API.Running=false
        generation+=1
        if API.MovementCollisionRestore then API.MovementCollisionRestore() end
        cancelOwnedCast()
        if driveCleanup then driveCleanup() end
        if API.EarningForRod and type(ShelfStocking.cancel_stocking)=="function" then pcall(ShelfStocking.cancel_stocking) end
        Sprint.sprinting.set(false)
        h:UnequipTools()
        h:MoveTo(root.Position)
        bindCharacter(c,h,root)
        p.State="Hiding while combat is active"
        p.ActivatedAt=os.clock()
        p.ClearAttempts=0
        clearedAt=nil
    end
    local function hold()
        if not API.ProtectionActive then return end
        if player.Character and player.Character~=hiddenCharacter then
            local c=player.Character
            local root=c:FindFirstChild("HumanoidRootPart")
            local h=c:FindFirstChildOfClass("Humanoid")
            if not root or not h then return end
            bindCharacter(c,h,root)
        end
        local root=hiddenCharacter and hiddenCharacter:FindFirstChild("HumanoidRootPart")
        local h=hiddenCharacter and hiddenCharacter:FindFirstChildOfClass("Humanoid")
        if not root or not h or not hideAt then return end
        for _,part in ipairs(hiddenCharacter:QueryDescendants("BasePart")) do
            if savedParts[part]==nil then savedParts[part]=part.CanCollide end
            part.CanCollide=false
            part.AssemblyLinearVelocity=Vector3.zero
            part.AssemblyAngularVelocity=Vector3.zero
        end
        local clearance=math.clamp(Config.ProtectionHideDepth,4,30)
        local highestOffset=math.max(0,bodyTop(hiddenCharacter)-root.Position.Y)
        local targetY=math.max(groundY-80,math.min(hideAt.Y,groundY-clearance-highestOffset))
        hideAt=Vector3.new(hideAt.X,targetY,hideAt.Z)
        local target=CFrame.new(hideAt)*surface.Rotation
        -- Transform the complete ragdoll, including detached or disabled-motor limbs.
        hiddenCharacter:PivotTo(target*root.CFrame:Inverse()*hiddenCharacter:GetPivot())
        p.HideTopY=bodyTop(hiddenCharacter)
        p.HideClearance=groundY-p.HideTopY
        p.FullyHidden=p.HideClearance>=clearance-0.25
        if h.Health>0 and os.clock()-lastPulse>=0.1 then
            lastPulse=os.clock()
            h:ChangeState(Enum.HumanoidStateType.Swimming)
        end
    end
    connections[#connections+1]=RunService.Stepped:Connect(function()
        if enabled() and API.ProtectionActive then hold() end
    end)
    connections[#connections+1]=RunService.Heartbeat:Connect(function()
        if not enabled() or not Config.AntiKill then
            if API.ProtectionActive then p.Stop() end
            return
        end
        local c,h,root=character()
        if not API.ProtectionActive then
            if API.Running and (API.AutoPlayCompleted or DeathScreen.enabled.get()) and h and root then
                local downed=h:GetAttribute("Stunned")==true and h.Health<=Config.ProtectionHealthThreshold
                if downed or h.Health<=0 or h:GetAttribute("IsDead")==true then activate(c,h,root) end
            end
            return
        end
        hold()
        status(p.State)
        if not combatClear() then clearedAt=nil return end
        clearedAt=clearedAt or os.clock()
        if os.clock()-clearedAt<Config.CombatClearDelay then return end
        p.State="Combat ended - switching to a low population server"
        if not p.Pending and not p.Searching and os.clock()-lastAttempt>=15 then
            lastAttempt=os.clock()
            p.Searching=true
            local serial=p.Serial
            task.spawn(function()
                local ok,errorText=pcall(p.Hop,"Anti Kill recovery",false)
                if serial==p.Serial then
                    p.Searching=false
                    p.ClearAttempts+=1
                    if not ok then p.LastError=tostring(errorText) end
                    if p.ClearAttempts>=5 and not p.Pending then
                        API.LastWarning="Protection server switch failed: "..tostring(p.LastError or p.HopState)
                        p.Stop()
                    end
                end
            end)
        end
    end)
    return p
end)()


local lakeSupport,lakeTravel,skyTravel,skyStop
local function updateTravelSprint()
    local stamina=Sprint.sprint_bar.get()
    if stamina<0.05 then Sprint.sprinting.set(false)
    elseif stamina>0.3 then Sprint.sprinting.set(true) end
end
local function updateSwimmingSprint()
    if not Config.SprintWhileSwimming then Sprint.sprinting.set(false) return end
    updateTravelSprint()
end
local function clearLakeSupport()
    if lakeSupport then lakeSupport:Destroy() lakeSupport=nil end
    API.AtLakeCenter=false
end
function API.Stop(message,retrying)
    if not retrying then API.ManualStopSerial=(API.ManualStopSerial or 0)+1 API.NextRetryAt=nil end
    if API.MovementCollisionRestore then API.MovementCollisionRestore() end
    if API.Protection then API.Protection.Stop() end
    Config.Enabled = false
    API.Running = false
    API.Travelling = false
    Sprint.sprinting.set(false)
    if driveCleanup then driveCleanup() end
    if skyStop then skyStop() end
    clearLakeSupport()
    if API.EarningForRod and type(ShelfStocking.cancel_stocking)=="function" then pcall(ShelfStocking.cancel_stocking) end
    generation += 1
    cancelOwnedCast()
    local _, h, root = character()
    if h and root then h:MoveTo(root.Position) end
    status(message or "Paused")
end
function API.Retry(message)
    if not Config.Enabled or destroyed or API.ProtectionActive then return end
    local reason=tostring(message):match(":%d+: (.*)") or tostring(message)
    API.LastError=reason
    API.LastRetryReason=reason
    if not Config.AutoRetryErrors then API.Stop("Error: "..reason) return end
    API.RetryCount=(API.RetryCount or 0)+1
    local delay=math.min(Config.MaxRetryDelay,Config.RetryDelay*API.RetryCount)
    local manualSerial=API.ManualStopSerial or 0
    API.Stop("Retry in "..delay.."s: "..reason,true)
    if destroyed or (API.ManualStopSerial or 0)~=manualSerial then return end
    API.NextRetryAt=os.clock()+delay
    Config.Enabled=true
    logEvent("WARN","Automatic recovery scheduled: "..reason,"auto-retry",0.5)
end

local function walkToSpot(token, destination, caption)
    destination = destination or API.Spot
    if not alive(token) then return false end
    local c, h, root = character()
    if not root or not h or h.Health <= 0 then return false, "Character unavailable" end
    local function horizontal(a, b) return Vector3.new(a.X-b.X,0,a.Z-b.Z).Magnitude end
    if horizontal(root.Position, destination) < 3 and math.abs(root.Position.Y-destination.Y)<6 then return true end
    if h.SeatPart then
        -- Patio chairs can seat the character while crossing a shop approach.
        h.Sit=false
        h:ChangeState(Enum.HumanoidStateType.GettingUp)
        local untilTime=os.clock()+1
        repeat task.wait(0.05) until not alive(token) or not h.SeatPart or os.clock()>untilTime
        if not alive(token) then return false end
        if h.SeatPart then return false,"Unable to stand up from seat" end
    end
    status(caption or "Walking to the fishing spot")
    logEvent("MOVE",string.format("Destination %s; %.0f studs away",tostring(destination),horizontal(root.Position,destination)),"move-goal",0.2)
    local function navMode(mode,detail)
        if API.MovementMode~=mode then
            API.MovementMode=mode
            logEvent("MOVE",mode..(detail and (": "..detail) or ""),"navigation",0.6)
        end
    end
    local function jumpObstacle()
        if not Config.AllowGroundJump then return end
        if h.FloorMaterial == Enum.Material.Air then return end
        h.Jump = true
        h:ChangeState(Enum.HumanoidStateType.Jumping)
    end
    local lastVault = -math.huge
    local obstacleCooldown=setmetatable({},{__mode="k"})
    local function shortNoclip(direction)
        if not Config.ObstacleNoclip or os.clock()-(API.LastNoclipAt or -math.huge)<0.75 then return false end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances={c}
        params.RespectCanCollide=true
        local hit=workspace:Raycast(root.Position,direction*6,params)
            or workspace:Raycast(root.Position-Vector3.new(0,1.8,0),direction*6,params)
        if not hit or hit.Normal.Y>0.65 then return false end
        if os.clock()<(obstacleCooldown[hit.Instance] or 0) then return false end
        local overlap=OverlapParams.new()
        overlap.FilterType=Enum.RaycastFilterType.Exclude
        overlap.FilterDescendantsInstances={c}
        overlap.RespectCanCollide=true
        local origin=root.CFrame
        local bounds,boundsSize=c:GetBoundingBox()
        local boxOffset=bounds.Position-root.Position
        local boxSize=Vector3.new(math.clamp(boundsSize.X,2,4),math.clamp(boundsSize.Y,5,9),math.clamp(boundsSize.Z,2,4))
        local landing
        -- Find a clear standing position beyond the obstacle, with solid ground.
        for distance=math.max(3,math.ceil(hit.Distance+2)),math.clamp(Config.NoclipMaxDistance,3,10) do
            local point=root.Position+direction*distance
            local floor=workspace:Raycast(point+Vector3.new(0,2,0),Vector3.new(0,-10,0),params)
            if floor and floor.Material~=Enum.Material.Water and floor.Normal.Y>0.6 then
                local candidate=Vector3.new(point.X,floor.Position.Y+h.HipHeight+root.Size.Y/2,point.Z)
                if math.abs(candidate.Y-root.Position.Y)<4
                    and #workspace:GetPartBoundsInBox(CFrame.new(candidate+boxOffset),boxSize,overlap)==0 then
                    landing=candidate
                    break
                end
            end
        end
        if not landing then return false end
        local saved={}
        for _,part in ipairs(c:QueryDescendants("BasePart")) do saved[part]=part.CanCollide end
        local restored=false
        local function restoreCollision()
            if restored then return end
            restored=true
            for part,value in pairs(saved) do if part.Parent then part.CanCollide=value end end
            API.NoclipActive=false
            if API.MovementCollisionRestore==restoreCollision then API.MovementCollisionRestore=nil end
        end
        API.MovementCollisionRestore=restoreCollision
        API.LastNoclipAt=os.clock()
        API.NoclipActive=true
        logEvent("MOVE","Short noclip across "..hit.Instance.Name,"obstacle-crossing",0.5)
        local completed=false
        local ok=pcall(function()
            local duration=math.clamp(Config.NoclipDuration,0.1,0.5)
            local started=os.clock()
            while alive(token) and h.Health>0 and root.Parent do
                for part in pairs(saved) do if part.Parent then part.CanCollide=false end end
                local alpha=math.min((os.clock()-started)/duration,1)
                local point=origin.Position:Lerp(landing,alpha)
                root.CFrame=CFrame.lookAt(point,point+direction)
                root.AssemblyLinearVelocity=Vector3.zero
                if alpha>=1 then completed=true break end
                RunService.Stepped:Wait()
            end
        end)
        -- Restore collisions on success, cancellation, death, and execution errors.
        if not completed and root.Parent and h.Health>0 and not API.ProtectionActive then root.CFrame=origin end
        restoreCollision()
        if ok and completed then
            task.wait(0.15)
            if not alive(token) then return false end
            if horizontal(root.Position,landing)>3 then
                obstacleCooldown[hit.Instance]=os.clock()+10
                logEvent("WARN","Obstacle crossing was corrected; choosing another route","crossing-corrected",2)
                return false
            end
            API.NoclipPasses=(API.NoclipPasses or 0)+1
            return true
        end
        return false
    end
    local function vaultShortObstacle(direction)
        if not Config.AllowFootVault then return false end
        if shortNoclip(direction) then return true end
        if os.clock()-lastVault<Config.VaultDuration+0.15 then return false end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances={c}
        params.RespectCanCollide=true
        local hit=workspace:Raycast(root.Position-Vector3.new(0,1.8,0),direction*7,params) or workspace:Raycast(root.Position,direction*7,params)
        if not hit then return false end
        local landingXZ=root.Position+direction*10
        local clear=workspace:Raycast(root.Position+Vector3.new(0,13,0),direction*10,params)
        local floor=workspace:Raycast(landingXZ+Vector3.new(0,14,0),Vector3.new(0,-28,0),params)
        local standingFloorY=root.Position.Y-h.HipHeight-root.Size.Y/2
        if clear or not floor or floor.Material==Enum.Material.Water or floor.Position.Y>standingFloorY+2
            or floor.Position.Y<standingFloorY-Config.MovementMaxStepDown then return false end
        lastVault=os.clock()
        logEvent("MOVE","Short vault over "..hit.Instance.Name,"obstacle-crossing",0.5)
        -- User-authorized obstacle flight: one short arc, always less than one second.
        local origin=root.Position
        local landing=Vector3.new(landingXZ.X,floor.Position.Y+h.HipHeight+root.Size.Y/2,landingXZ.Z)
        local arcHeight=3.5
        local clearance=OverlapParams.new()
        clearance.FilterDescendantsInstances={c}
        clearance.RespectCanCollide=true
        for sample=1,9 do
            local alpha=sample/10
            local point=origin:Lerp(landing,alpha)+Vector3.new(0,math.sin(alpha*math.pi)*arcHeight,0)
            if #workspace:GetPartBoundsInBox(CFrame.new(point),Vector3.new(2,4.8,2),clearance)>0 then return false end
        end
        local started=os.clock()
        API.ObstacleFlights=(API.ObstacleFlights or 0)+1
        while alive(token) and os.clock()-started<Config.VaultDuration do
            local alpha=math.min((os.clock()-started)/Config.VaultDuration,1)
            local point=origin:Lerp(landing,alpha)+Vector3.new(0,math.sin(alpha*math.pi)*arcHeight,0)
            root.CFrame=CFrame.lookAt(point,point+direction)
            root.AssemblyLinearVelocity=Vector3.zero
            RunService.Heartbeat:Wait()
        end
        if alive(token) then root.CFrame=CFrame.lookAt(landing,landing+direction) end
        API.LastVaultDuration=os.clock()-started
        return true
    end
    local sensing=RaycastParams.new()
    sensing.FilterType=Enum.RaycastFilterType.Exclude
    sensing.FilterDescendantsInstances={c}
    sensing.RespectCanCollide=true
    local function floorAt(point)
        local floor=workspace:Raycast(point+Vector3.new(0,4,0),Vector3.new(0,-18,0),sensing)
        if floor and floor.Material~=Enum.Material.Water and floor.Normal.Y>0.6 then return floor end
    end
    local function clearSegment(target)
        local delta=Vector3.new(target.X-root.Position.X,0,target.Z-root.Position.Z)
        if delta.Magnitude<0.1 then return true end
        local side=Vector3.new(-delta.Z,0,delta.X).Unit*1.3
        for _,offset in ipairs({Vector3.zero,side,-side}) do
            if workspace:Raycast(root.Position+offset,delta,sensing)
                or workspace:Raycast(root.Position+offset-Vector3.new(0,1.7,0),delta,sensing) then return false end
        end
        local previousY=root.Position.Y-h.HipHeight-root.Size.Y/2
        for distance=math.min(5,delta.Magnitude),delta.Magnitude+0.1,5 do
            local floor=floorAt(root.Position+delta.Unit*distance)
            if not floor or floor.Position.Y-previousY>3.5 or previousY-floor.Position.Y>Config.MovementMaxStepDown then return false end
            previousY=floor.Position.Y
        end
        local floor=floorAt(Vector3.new(target.X,root.Position.Y,target.Z))
        return floor~=nil and floor.Position.Y-previousY<=3.5 and previousY-floor.Position.Y<=Config.MovementMaxStepDown
    end
    local function reached(target,tolerance)
        return horizontal(root.Position,target)<(tolerance or 3) and math.abs(root.Position.Y-target.Y)<7
    end
    local function follow(target,timeout,invalidated,watchAhead)
        local deadline=os.clock()+timeout
        local progressPosition,progressAt=root.Position,os.clock()
        local started=root.Position
        local recoveries=0
        local bestRemaining,goalProgressAt=horizontal(root.Position,target),os.clock()
        h:MoveTo(target)
        while alive(token) and h.Health>0 and root.Parent and os.clock()<deadline do
            if reached(target,3) then return true end
            -- Advance smoothly when crossing a waypoint instead of turning back to it.
            local fromStart=Vector3.new(target.X-started.X,0,target.Z-started.Z)
            local remaining=Vector3.new(target.X-root.Position.X,0,target.Z-root.Position.Z)
            if remaining.Magnitude<5 and fromStart:Dot(remaining)<0 then return true end
            if invalidated and invalidated() then return false end
            if h.SeatPart then h.Sit=false h:ChangeState(Enum.HumanoidStateType.GettingUp) end
            if remaining.Magnitude<bestRemaining-0.5 then bestRemaining,goalProgressAt=remaining.Magnitude,os.clock() end
            if watchAhead and remaining.Magnitude>4 then
                local hit=workspace:Raycast(root.Position,remaining.Unit*math.min(4,remaining.Magnitude),sensing)
                if hit and hit.Normal.Y<0.65 and hit.Instance.Name~="DoorBase" then
                    API.LastObstacle=hit.Instance:GetFullName()
                    logEvent("MOVE","Obstacle ahead: "..hit.Instance.Name.."; replanning","obstacle-ahead",1)
                    return false
                end
            end
            if horizontal(root.Position,progressPosition)>1 then
                progressPosition,progressAt=root.Position,os.clock()
            end
            if os.clock()-progressAt>=Config.MovementStuckTime or os.clock()-goalProgressAt>=Config.MovementNoProgressTime then
                local direction=remaining.Magnitude>0.1 and remaining.Unit or nil
                local hit=direction and workspace:Raycast(root.Position,direction*6,sensing)
                local recovered=false
                -- Touch-operated doors need a little time before obstacle recovery.
                if hit and hit.Instance.Name=="DoorBase" and os.clock()-progressAt<1.4 then
                    h:MoveTo(target)
                else
                    API.StuckRecoveries=(API.StuckRecoveries or 0)+1
                    API.LastObstacle=hit and hit.Instance:GetFullName() or "No progress towards waypoint"
                    logEvent("MOVE","Stuck: "..(hit and hit.Instance.Name or "no forward progress").."; trying recovery","stuck",0.5)
                    if direction then recovered=vaultShortObstacle(direction) end
                    -- Recovery can land beyond the old waypoint. Replan there instead
                    -- of walking backwards into the obstacle to reach that waypoint.
                    if recovered then API.LastObstacleResponseTime=os.clock()-progressAt return false end
                    if not recovered then jumpObstacle() end
                    recoveries+=1
                    if recoveries>=2 then return false end
                    progressPosition,progressAt=root.Position,os.clock()
                    goalProgressAt=os.clock()
                    h:MoveTo(target)
                end
            end
            task.wait(Config.ObstaclePollInterval)
        end
        return reached(target,4)
    end
    local visits,blockedCells={},{}
    local lastDetourDirection
    local function cell(point)
        return tostring(math.floor(point.X/8))..":"..tostring(math.floor(point.Z/8))
    end
    local function detour()
        local origin=root.Position
        visits[cell(origin)]=(visits[cell(origin)] or 0)+1
        local delta=Vector3.new(destination.X-origin.X,0,destination.Z-origin.Z)
        if delta.Magnitude<0.1 then return false end
        local best,score,bestDirection
        for _,degrees in ipairs({0,35,-35,70,-70,110,-110,150,-150,180}) do
            local angle=math.rad(degrees)
            local d=delta.Unit
            local direction=Vector3.new(d.X*math.cos(angle)-d.Z*math.sin(angle),0,d.X*math.sin(angle)+d.Z*math.cos(angle))
            for _,distance in ipairs({6,10,14}) do
                local point=origin+direction*distance
                local floor=floorAt(point)
                local standingFloorY=origin.Y-h.HipHeight-root.Size.Y/2
                if (blockedCells[cell(point)] or 0)<os.clock() and floor
                    and floor.Position.Y-standingFloorY<=3.5 and standingFloorY-floor.Position.Y<=Config.MovementMaxStepDown
                    and clearSegment(point) then
                    local candidate=horizontal(point,destination)+(visits[cell(point)] or 0)*30
                        -(lastDetourDirection and lastDetourDirection:Dot(direction)*4 or 0)
                    if not score or candidate<score then best,score,bestDirection=floor.Position,candidate,direction end
                end
            end
        end
        if best then
            lastDetourDirection=bestDirection
            logEvent("MOVE",string.format("Taking clear detour: %.0f studs",horizontal(origin,best)),"detour",0.5)
            local moved=follow(best,horizontal(origin,best)/math.max(h.WalkSpeed,1)+1.5)
            if not moved then blockedCells[cell(best)]=os.clock()+8 end
            return moved
        end
        local recovered=vaultShortObstacle(delta.Unit)
        return recovered
    end
    local travelDeadline=os.clock()+math.max(45,horizontal(root.Position,destination)/math.max(h.WalkSpeed,1)*3+20)
    local failedPlans,totalPlans=0,0
    local bestDistance,bestAt=horizontal(root.Position,destination),os.clock()
    API.MovementGoal=tostring(destination)
    while alive(token) and h.Health>0 and root.Parent and os.clock()<travelDeadline do
        if reached(destination,4) then navMode("Arrived") return true end
        local currentDistance=horizontal(root.Position,destination)
        if currentDistance<bestDistance-5 then bestDistance,bestAt=currentDistance,os.clock() end
        if os.clock()-bestAt>12 or totalPlans>=12 then break end
        local delta=Vector3.new(destination.X-root.Position.X,0,destination.Z-root.Position.Z)
        if delta.Magnitude<0.1 then break end
        local range=math.min(math.clamp(Config.MovementLookAhead,10,40),delta.Magnitude)
        local direct=root.Position+delta.Unit*range
        if delta.Magnitude<=range then direct=destination end
        if clearSegment(direct) then
            navMode("Direct")
            if follow(direct,range/math.max(h.WalkSpeed,1)+2,nil,true) then failedPlans=0 continue end
        end
        if not alive(token) or h.Health<=0 then return false end
        navMode("Planning")
        totalPlans+=1
        API.MovementReplans=(API.MovementReplans or 0)+1
        logEvent("MOVE","Replanning route; attempt "..totalPlans,"route-plan",1)
        player:RequestStreamAroundAsync(root.Position+delta.Unit*math.min(100,delta.Magnitude),1)
        local agentHeight=math.clamp(math.ceil(c:GetExtentsSize().Y),5,9)
        local agentRadius=math.clamp(root.Size.X/2+0.2,1.2,2)
        local path=Pathfinding:CreatePath({AgentRadius=agentRadius,AgentHeight=agentHeight,AgentCanJump=Config.AllowGroundJump,AgentCanClimb=false,WaypointSpacing=6,Costs={Water=100000}})
        local computed=pcall(function() path:ComputeAsync(root.Position,destination) end)
        if not alive(token) then return false end
        local advanced=false
        if computed and path.Status==Enum.PathStatus.Success then
            navMode("Following path")
            local points=path:GetWaypoints()
            local index=1
            local dirty=false
            local blockedConnection=path.Blocked:Connect(function(blockedIndex)
                if blockedIndex>=index then dirty=true end
            end)
            local ok=pcall(function()
                while index<=#points and alive(token) and not dirty do
                    while index<#points and reached(points[index].Position,3) do index+=1 end
                    local chosen=index
                    for nextIndex=index+1,math.min(index+7,#points) do
                        local point=points[nextIndex]
                        if point.Action==Enum.PathWaypointAction.Jump or horizontal(root.Position,point.Position)>Config.MovementLookAhead
                            or not clearSegment(point.Position) then break end
                        chosen=nextIndex
                    end
                    index=chosen
                    local point=points[index]
                    if point.Action==Enum.PathWaypointAction.Jump then h.Jump=true end
                    local limit=horizontal(root.Position,point.Position)/math.max(h.WalkSpeed,1)+2
                    if not follow(point.Position,limit,function()return dirty end) then break end
                    advanced=true
                    index+=1
                end
            end)
            blockedConnection:Disconnect()
            if not ok then advanced=false end
        end
        if reached(destination,4) then navMode("Arrived") return true end
        if advanced then failedPlans=0 else failedPlans+=1 end
        if not advanced then
            navMode("Local recovery")
            if detour() then failedPlans=0 end
        end
        if failedPlans>=6 then break end
        task.wait(0.05)
    end
    navMode("Blocked","No clear route after bounded retries")
    return false,"Could not find a clear route after replanning"
end


local footRoute=walkToSpot
local function walkingRoute(token,destination,caption)
    local wasTravelling,wasTransport=API.Travelling,API.Transport
    API.Travelling=true
    API.Transport="Running"
    updateTravelSprint()
    local ok,reached,why=pcall(footRoute,token,destination,caption)
    API.Travelling=wasTravelling
    API.Transport=wasTransport
    Sprint.sprinting.set(false)
    if not ok then error(reached) end
    return reached,why
end
-- Road junctions observed during the original script's travel, plus map pier approaches.
local roads = {
    Vector3.new(100,251,-660), Vector3.new(40,251,-577), Vector3.new(0,251,-350),
    Vector3.new(0,251,0), Vector3.new(-100,251,80), Vector3.new(-290,251,-250),
    Vector3.new(-290,251,0), Vector3.new(-290,251,300), Vector3.new(-292,251,365),
    Vector3.new(0,251,580), Vector3.new(180,251,600), Vector3.new(-360,251,650),
    Vector3.new(450,251,0), Vector3.new(950,251,600), Vector3.new(950,251,0),
    Vector3.new(780,251,-590), Vector3.new(450,251,-580), Vector3.new(950,251,-600),
}
local roadEdges={{1,2},{2,3},{3,4},{4,5},{3,6},{6,7},{7,8},{8,9},{4,7},{4,10},{10,11},{10,12},{4,13},{13,15},{15,14},{11,14},{16,17},{17,2},{16,18},{18,15}}
local function roadRoute(origin,destination)
    local function closest(point)
        local index,delta
        for i,p in ipairs(roads) do
            local d=Vector3.new(p.X-point.X,0,p.Z-point.Z).Magnitude
            if not delta or d<delta then index,delta=i,d end
        end
        return index
    end
    local start,finish=closest(origin),closest(destination)
    local distances,previous,visited={[start]=0},{},{}
    for _=1,#roads do
        local current,best
        for i,d in pairs(distances) do if not visited[i] and (not best or d<best) then current,best=i,d end end
        if not current or current==finish then break end
        visited[current]=true
        for _,edge in ipairs(roadEdges) do
            local neighbor=edge[1]==current and edge[2] or edge[2]==current and edge[1]
            if neighbor then
                local cost=best+(roads[current]-roads[neighbor]).Magnitude
                if not distances[neighbor] or cost<distances[neighbor] then distances[neighbor],previous[neighbor]=cost,current end
            end
        end
    end
    local route={roads[finish]}
    local cursor=finish
    while previous[cursor] do cursor=previous[cursor] table.insert(route,1,roads[cursor]) end
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances={player.Character,workspace.Vehicles}
    params.RespectCanCollide=true
    local function clearStreet(a,b)
        local from=Vector3.new(a.X,255.2,a.Z)
        local delta=Vector3.new(b.X-a.X,0,b.Z-a.Z)
        if delta.Magnitude<0.1 then return true end
        local side=Vector3.new(-delta.Z,0,delta.X).Unit*1.5
        for _,offset in ipairs({Vector3.zero,side,-side}) do
            if workspace:Raycast(from+offset,delta,params)
                or workspace:Raycast(from+offset-Vector3.new(0,1.7,0),delta,params) then return false end
        end
        return true
    end
    local expanded={}
    local from=origin
    for _,point in ipairs(route) do
        -- Diagonal junction links can cut across the inside of a city block.
        -- Use a clear right-angle corner when the direct street link hits a wall.
        if math.abs(point.X-from.X)>15 and math.abs(point.Z-from.Z)>15 and not clearStreet(from,point) then
            for _,corner in ipairs({Vector3.new(from.X,251,point.Z),Vector3.new(point.X,251,from.Z)}) do
                if clearStreet(from,corner) and clearStreet(corner,point) then table.insert(expanded,corner) break end
            end
        end
        table.insert(expanded,point)
        from=point
    end
    return expanded
end
local function ownedTravelVehicle()
    local found,foundType,blocked
    local _,hum,root=character()
    local spawned={}
    if root then
        for _,model in ipairs(workspace.Vehicles:GetChildren()) do
            if model:GetAttribute("OwnerUserId")==player.UserId then
                local guid=model:GetAttribute("ItemGUID")
                local seat=model:FindFirstChild("DriverSeat",true)
                if guid and seat and validWorldPosition(seat.Position) and (not seat.Occupant or seat.Occupant==hum) then
                    spawned[guid]=(seat.Position-root.Position).Magnitude
                end
            end
        end
    end
    for _,kind in ipairs({"car","bike"}) do
        if kind=="car" and not Config.PreferOwnedCars then continue end
        local nearby,nearDistance
        Items.iterate_through_items_of_type(Data,kind,function(item)
            if item.location=="hand" and not item.destroyed and (item.health or 1)>0
                and (kind=="car" or kind=="bike") then
                local distance=spawned[item.guid]
                local range=kind=="car" and Config.CarNearbyDistance or Config.ScooterNearbyDistance
                if distance and distance<=range and (not nearDistance or distance<nearDistance) then
                    nearby,nearDistance=item,distance
                end
                if kind=="car" and API.VehicleRetryAfter and (API.VehicleRetryAfter[item.guid] or 0)>os.clock() then
                    blocked=blocked or item
                    return
                end
                if not found or (item.health or 1)>(found.health or 1)
                    or ((item.health or 1)==(found.health or 1) and item.name<found.name) then found,foundType=item,kind end
            end
        end)
        if nearby then
            API.VehicleSelectionReason="Nearby spawned vehicle"
            return nearby,kind
        end
        API.VehicleSelectionReason="Inventory vehicle"
        if found then return found,foundType end
        if kind=="car" and blocked then return blocked,"car" end
    end
end
local function tryOwnedTransport(token, destination)
    local c,h,root=character()
    local owned,vehicleType=ownedTravelVehicle()
    API.TransportTripResult="Unavailable"
    if not root or not owned or type(fireproximityprompt)~="function" then return false end
    if not validWorldPosition(root.Position) then API.LastTransportError="Character position is invalid" return false end
    local minimum=vehicleType=="car" and Config.CarMinTripDistance or Config.ScooterMinTripDistance
    if (root.Position-destination).Magnitude<minimum then return false end
    local function indoors(p)
        return (p.X>-170 and p.X<-98 and p.Z>96 and p.Z<174)
            or (p.X>-288 and p.X<-236 and p.Z>330 and p.Z<412)
            or (p.X>235 and p.X<276 and p.Z<-236 and p.Z>-292)
            or (p.X>55 and p.X<165 and p.Z>476 and p.Z<580 and p.Y>248 and p.Y<263)
    end
    if indoors(root.Position) or indoors(destination) then API.TransportTripResult="Indoor" return false end
    API.SelectedVehicle={Name=owned.name,Guid=owned.guid,Type=vehicleType,Reason=API.VehicleSelectionReason}
    API.Transport=owned.name
    status("Using inventory "..owned.name)
    local function findScooter()
        local fallback
        for _,v in ipairs(workspace.Vehicles:GetChildren()) do
            if v:GetAttribute("OwnerUserId")==player.UserId and validWorldPosition(v:GetPivot().Position) then
                local guid=v:GetAttribute("ItemGUID")
                if guid==owned.guid then return v end
                if not guid and v.Name==owned.name then fallback=v end
            end
        end
        return fallback
    end
    local function awaitVehicleState(predicate,timeout)
        local deadline=os.clock()+timeout
        repeat
            if predicate() then return true end
            if not alive(token) then return false end
            task.wait(0.05)
        until os.clock()>=deadline
        return predicate()
    end
    local function toggleScooter(action)
        local deadline=os.clock()+(vehicleType=="car" and Config.VehicleCooldownMaxWait or Config.ScooterCooldownWait)
        repeat
            if not alive(token) then return false end
            local nextSpawn=player:GetAttribute("SpawnVehicleNext")
            if type(nextSpawn)=="number" and nextSpawn>workspace:GetServerTimeNow() then
                status(owned.name.." cooldown: "..math.ceil(nextSpawn-workspace:GetServerTimeNow()).."s")
                repeat
                    task.wait(0.5)
                    local candidate=ownedTravelVehicle()
                    if candidate and candidate.guid~=owned.guid and API.VehicleSelectionReason=="Nearby spawned vehicle" then
                        API.LastTransportError="Nearby owned vehicle became available; changing selection"
                        return false
                    end
                until not alive(token) or workspace:GetServerTimeNow()>=nextSpawn or os.clock()>=deadline
                if not alive(token) then return false end
                if os.clock()>=deadline then API.LastTransportError="Waiting for vehicle spawn cooldown" return false end
            end
            local accepted,reason=netGet("toggle_equip_item",owned.guid)
            API.LastVehicleReply={Action=action,Accepted=accepted,Reason=reason}
            if accepted then return true end
            if reason~="Cooldown" or os.clock()>=deadline then
                API.LastTransportError=action.." rejected: "..tostring(reason)
                if vehicleType=="car" and reason=="Cooldown" then
                    API.VehicleRetryAfter=API.VehicleRetryAfter or {}
                    API.VehicleRetryAfter[owned.guid]=os.clock()+30
                end
                return false
            end
            status(owned.name.." cooldown - retrying "..action)
            task.wait(1.5)
        until not alive(token)
        return false
    end
    Sprint.sprinting.set(false)
    h:MoveTo(root.Position)
    local existing=findScooter()
    local refreshed=false
    local existingSeat=existing and existing:FindFirstChild("DriverSeat",true)
    local nearby=vehicleType=="car" and Config.CarNearbyDistance or Config.ScooterNearbyDistance
    if existing and ((existingSeat and existingSeat.Position or existing:GetPivot().Position)-root.Position).Magnitude>nearby then
        local driver=existingSeat
        if driver and driver.Occupant and driver.Occupant~=h then API.LastTransportError="Owned scooter is occupied" return false end
        status("Despawning distant "..owned.name)
        if not toggleScooter("despawn") then
            return false
        else
            if not awaitVehicleState(function()return not existing.Parent or not validWorldPosition(existing:GetPivot().Position) end,3) then
                API.LastTransportError="Despawn not confirmed; spawn was not attempted"
                return false
            end
            existing=nil
            refreshed=true
        end
    end
    if not existing then
        status("Spawning "..owned.name.." beside character")
        if not toggleScooter("spawn") then return false end
        if not awaitVehicleState(function()return findScooter()~=nil end,3) then
            API.LastTransportError="Vehicle spawn not replicated"
            return false
        end
    end
    if refreshed then API.ScooterRefreshes=(API.ScooterRefreshes or 0)+1 end
    if not alive(token) then return false end
    local vehicle=findScooter()
    if not vehicle then API.LastTransportError="Vehicle spawn not replicated" return false end
    local seat=vehicle:FindFirstChild("DriverSeat",true)
    local prompt=vehicle:FindFirstChild("DrivePrompt",true)
    if not seat or not prompt then return false end
    API.LastScooterSpawnDistance=(seat.Position-root.Position).Magnitude
    API.VehicleLocation={Guid=vehicle:GetAttribute("ItemGUID"),Position=tostring(seat.Position),Distance=API.LastScooterSpawnDistance}
    logEvent("MOVE","Owned "..owned.name.." seat: "..tostring(seat.Position).."; distance="..math.floor(API.LastScooterSpawnDistance))
    if (root.Position-seat.Position).Magnitude>10 then
        local toward=root.Position-seat.Position
        local approach=seat.Position+(toward.Magnitude>0.1 and toward.Unit*5 or Vector3.new(0,0,5))
        if vehicleType=="car" then
            local _,carSize=vehicle:GetBoundingBox()
            local side=vehicle:GetPivot().RightVector*(carSize.X/2+2)
            local a,b=seat.Position+side,seat.Position-side
            approach=(a-root.Position).Magnitude<(b-root.Position).Magnitude and a or b
        end
        local reached=walkingRoute(token,approach,"Running to owned "..owned.name)
        if not reached then return false end
    end
    if h.SeatPart~=seat then fireproximityprompt(prompt) end
    local deadline=os.clock()+2
    repeat task.wait(0.1) until not alive(token) or h.SeatPart==seat or os.clock()>deadline
    if h.SeatPart~=seat then API.LastTransportError="Scooter mounting failed" return false end
    API.TransportTrips=(API.TransportTrips or 0)+1
    API.LastTransportError=nil
    Sprint.sprinting.set(false)
    local controls=require(player.PlayerScripts.PlayerModule):GetControls()
    controls:Disable()
    local clearDrive
    local function planBikeRoute(goal)
        local start=root.Position
        local toward=Vector3.new(goal.X-start.X,0,goal.Z-start.Z)
        toward=toward.Magnitude>0.1 and toward.Unit or Vector3.xAxis
        local seeds={start}
        -- The parked vehicle itself can occupy the starting navmesh cell.
        for _,angle in ipairs({0,45,-45,90,-90,135,-135,180}) do
            seeds[#seeds+1]=start+CFrame.Angles(0,math.rad(angle),0):VectorToWorldSpace(toward)*6
        end
        for i,seed in ipairs(seeds) do
            if i==1 or clearDrive(vehicle:GetPivot().Position,seed) then
                local path=Pathfinding:CreatePath({AgentRadius=Config.BikeAgentRadius,AgentHeight=5,AgentCanJump=false,AgentCanClimb=false,WaypointSpacing=6})
                local ok=pcall(function()path:ComputeAsync(seed,goal) end)
                if not alive(token) then return nil end
                if ok and path.Status==Enum.PathStatus.Success then
                    local points={}
                    for _,waypoint in ipairs(path:GetWaypoints()) do
                        if waypoint.Action==Enum.PathWaypointAction.Jump then return nil end
                        points[#points+1]=waypoint.Position
                    end
                    return points
                end
            end
        end
    end
    local groundParams=RaycastParams.new()
    groundParams.FilterType=Enum.RaycastFilterType.Include
    groundParams.FilterDescendantsInstances={workspace.Terrain,workspace.Map}
    groundParams.RespectCanCollide=true
    groundParams.IgnoreWater=false
    local obstacleParams=RaycastParams.new()
    obstacleParams.FilterType=Enum.RaycastFilterType.Exclude
    local obstacleExclusions={c,vehicle}
    if workspace:FindFirstChild("TerrainDecor") then obstacleExclusions[#obstacleExclusions+1]=workspace.TerrainDecor end
    obstacleParams.FilterDescendantsInstances=obstacleExclusions
    obstacleParams.RespectCanCollide=true
    local bounds,size=vehicle:GetBoundingBox()
    local offset=vehicle:GetPivot().Position.Y-(bounds.Position.Y-size.Y/2)+0.08
    local chassis=vehicle:FindFirstChild("Chassis") or vehicle.PrimaryPart
    local function brake()
        if chassis and chassis.Parent then
            chassis.AssemblyLinearVelocity=Vector3.zero
            chassis.AssemblyAngularVelocity=Vector3.zero
        end
    end
    local undergroundRestore
    local cleaned=false
    local function cleanup()
        if cleaned then return end
        cleaned=true
        if undergroundRestore then undergroundRestore() undergroundRestore=nil end
        brake()
        if seat.Parent then seat.ThrottleFloat=0 seat.SteerFloat=0 end
        controls:Enable()
        if h.Parent and h.SeatPart==seat then pcall(netGet,"exit_seat") h.Sit=false end
        driveCleanup=nil
    end
    driveCleanup=cleanup
    local function floorAt(position)
        if not validWorldPosition(position) then return nil end
        local hit=workspace:Raycast(position+Vector3.new(0,8,0),Vector3.new(0,-24,0),groundParams)
        if hit and hit.Material~=Enum.Material.Water and hit.Normal.Y>0.7 then return hit.Position end
    end
    local function stepOutOfCar()
        if vehicleType~="car" or not alive(token) or h.Health<=0 or h.SeatPart then return end
        if not vehicle.Parent or not validWorldPosition(vehicle:GetPivot().Position) then return end
        local pivot=vehicle:GetPivot()
        local query=OverlapParams.new()
        query.FilterDescendantsInstances={c}
        query.RespectCanCollide=true
        local height=math.max(5,h.HipHeight*2+root.Size.Y)
        for _,side in ipairs({pivot.RightVector,-pivot.RightVector,pivot.LookVector,-pivot.LookVector}) do
            local distance=(math.abs(side:Dot(pivot.RightVector))>0.5 and size.X or size.Z)/2+3
            local point=pivot.Position+side*distance
            local floor=floorAt(point)
            if floor then
                local center=floor+Vector3.new(0,height/2+0.15,0)
                if #workspace:GetPartBoundsInBox(CFrame.new(center),Vector3.new(2.2,height,2.2),query)==0 then
                    local standing=floor+Vector3.new(0,h.HipHeight+root.Size.Y/2+0.1,0)
                    root.CFrame=CFrame.new(standing)*root.CFrame.Rotation
                    root.AssemblyLinearVelocity=Vector3.zero
                    logEvent("MOVE","Exited car beside vehicle")
                    return
                end
            end
        end
        API.LastWarning="No clear position beside car for dismount"
    end
    if Config.UndergroundVehicleTravel and vehicleType=="car" then
        local origin=vehicle:GetPivot()
        local startFloor=floorAt(origin.Position)
        local toward=Vector3.new(destination.X-origin.Position.X,0,destination.Z-origin.Position.Z)
        toward=toward.Magnitude>0.1 and toward.Unit or Vector3.xAxis
        local overlap=OverlapParams.new()
        overlap.FilterDescendantsInstances={c,vehicle}
        overlap.RespectCanCollide=true
        local clearance=Vector3.new(math.max(3,size.X+0.5),math.max(6,size.Y+2),math.max(4,size.Z+0.5))
        local function surfaceSpot(point)
            local floor=floorAt(Vector3.new(point.X,destination.Y,point.Z))
            if not floor then return nil end
            local box=CFrame.new(floor+Vector3.new(0,clearance.Y/2+0.15,0))
            if #workspace:GetPartBoundsInBox(box,clearance,overlap)>0 then return nil end
            return Vector3.new(point.X,floor.Y+offset,point.Z),floor.Y
        end
        local exit,exitFloor
        for _,distance in ipairs({Config.VehicleSurfaceDistance,15,25,35}) do
            for _,angle in ipairs({0,45,-45,90,-90,135,-135,180}) do
                local direction=CFrame.Angles(0,math.rad(angle),0):VectorToWorldSpace(-toward)
                exit,exitFloor=surfaceSpot(destination+direction*distance)
                if exit then break end
            end
            if exit then break end
        end
        if startFloor and exit then
            local saved={}
            local recovery=origin
            local submerged=false
            local restored=false
            local function disableCollisions()
                for _,model in ipairs({vehicle,c}) do
                    for _,part in model:QueryDescendants("BasePart") do
                        if saved[part]==nil then saved[part]=part.CanCollide end
                        part.CanCollide=false
                    end
                end
            end
            undergroundRestore=function()
                if restored then return end
                restored=true
                if submerged and vehicle.Parent and validWorldPosition(vehicle:GetPivot().Position) and h.Health>0 and not API.ProtectionActive then vehicle:PivotTo(recovery) end
                for part,collide in pairs(saved) do if part.Parent then part.CanCollide=collide end end
                API.UndergroundActive=false
                API.UndergroundPhase="Idle"
                brake()
            end
            local function phase(name)
                API.UndergroundPhase=name
                status(owned.name.." - "..name)
                logEvent("MOVE","Underground vehicle: "..name)
            end
            local function moveFrame(position,direction)
                assert(validWorldPosition(position) and direction.X==direction.X and direction.Magnitude>0.01,"Invalid vehicle movement frame")
                disableCollisions()
                vehicle:PivotTo(CFrame.lookAt(position,position+direction))
                brake()
                API.VehicleLocation={Guid=owned.guid,Position=tostring(seat.Position),Underground=true}
            end
            local function transition(target,duration)
                local from=vehicle:GetPivot().Position
                local begun=os.clock()
                repeat
                    if not alive(token) or h.Health<=0 or not seat.Parent or h.SeatPart~=seat then return false end
                    local alpha=math.clamp((os.clock()-begun)/duration,0,1)
                    moveFrame(from:Lerp(target,alpha),toward)
                    if alpha>=1 then return true end
                    RunService.Heartbeat:Wait()
                until false
            end
            local depth=math.clamp(Config.UndergroundVehicleDepth,8,35)
            local tunnelY=math.min(startFloor.Y,exitFloor)-depth
            API.UndergroundActive=true
            API.UndergroundExit=tostring(exit)
            phase("Descending below ground")
            submerged=true
            local ok=transition(Vector3.new(origin.Position.X,tunnelY,origin.Position.Z),math.max(0.2,Config.VehicleDiveDuration))
            if ok then
                phase("Travelling below ground")
                local distance=Vector3.new(exit.X-origin.Position.X,0,exit.Z-origin.Position.Z).Magnitude
                local speed=math.clamp(Config.UndergroundVehicleSpeed,10,120)
                local currentSpeed=math.min(20,speed)
                local acceleration=math.max(10,Config.UndergroundVehicleAcceleration)
                local braking=math.max(10,Config.UndergroundVehicleBraking)
                local deadline=os.clock()+distance/speed*2+15
                local previous,lastProgress=vehicle:GetPivot().Position,os.clock()
                local lastRecovery=0
                while alive(token) and h.Health>0 and seat.Parent and h.SeatPart==seat do
                    local position=vehicle:GetPivot().Position
                    if not validWorldPosition(position) then ok=false API.LastTransportError="Vehicle despawned or left valid world" break end
                    local delta=Vector3.new(exit.X-position.X,0,exit.Z-position.Z)
                    if delta.Magnitude<1 then break end
                    if os.clock()>deadline or os.clock()-lastProgress>3 then ok=false API.LastTransportError="Underground vehicle made no progress" break end
                    if (position-previous).Magnitude>2 then previous,lastProgress=position,os.clock() end
                    local dt=math.min(RunService.Heartbeat:Wait(),0.05)
                    if not alive(token) or h.SeatPart~=seat then ok=false break end
                    local targetSpeed=math.min(speed,math.sqrt(2*braking*math.max(0,delta.Magnitude-1)))
                    local rate=targetSpeed<currentSpeed and braking or acceleration
                    currentSpeed+=math.clamp(targetSpeed-currentSpeed,-rate*dt,rate*dt)
                    API.UndergroundCurrentSpeed=currentSpeed
                    local nextPosition=position+delta.Unit*math.min(currentSpeed*dt,delta.Magnitude)
                    -- Keep below lower terrain too, rather than breaking the surface mid-trip.
                    local surface=workspace:Raycast(Vector3.new(nextPosition.X,math.max(startFloor.Y,exitFloor)+6,nextPosition.Z),Vector3.new(0,-100,0),groundParams)
                    if surface then tunnelY=math.min(tunnelY,surface.Position.Y-depth) end
                    local y=position.Y+math.clamp(tunnelY-position.Y,-20*dt,20*dt)
                    moveFrame(Vector3.new(nextPosition.X,y,nextPosition.Z),delta.Unit)
                    if os.clock()-lastRecovery>1 then
                        local fallback=surfaceSpot(Vector3.new(nextPosition.X,destination.Y,nextPosition.Z))
                        if fallback then recovery=CFrame.lookAt(fallback,fallback+toward) end
                        lastRecovery=os.clock()
                    end
                end
                ok=ok and alive(token) and h.Health>0 and seat.Parent~=nil and h.SeatPart==seat
            end
            if ok then
                -- Recheck emergence clearance; another vehicle may have arrived meanwhile.
                local checked=surfaceSpot(exit)
                if checked then
                    exit=checked
                    phase("Surfacing near destination")
                    ok=transition(exit,math.max(0.2,Config.VehicleDiveDuration))
                    if ok then
                        recovery=vehicle:GetPivot()
                        submerged=false
                        API.UndergroundTrips=(API.UndergroundTrips or 0)+1
                        API.BikeRoutesCompleted=(API.BikeRoutesCompleted or 0)+1
                        API.LastTransportError=nil
                        API.TransportTripResult="Arrived"
                        logEvent("MOVE","Underground trip complete; walking final approach")
                    end
                else ok=false API.LastTransportError="Vehicle exit became obstructed" end
            end
            cleanup()
            task.wait(0.3)
            stepOutOfCar()
            return false
        end
        logEvent("MOVE","No clear underground exit; using ground route")
    end
    local halfWidth=math.clamp(size.X/2,0.85,1.35)
    clearDrive=function(a,b)
        local delta=Vector3.new(b.X-a.X,0,b.Z-a.Z)
        if delta.Magnitude<0.05 then return true end
        local floor=floorAt(a)
        if not floor then API.BikeRoadIssue="No ground at route start" return false end
        local side=Vector3.new(-delta.Z,0,delta.X).Unit*halfWidth
        for _,shift in ipairs({Vector3.zero,side,-side}) do
            for _,height in ipairs({1.8,3.2}) do
                local hit=workspace:Raycast(Vector3.new(a.X,floor.Y+height,a.Z)+shift,delta,obstacleParams)
                if hit then API.BikeBlockedPart=hit.Instance:GetFullName() return false end
            end
        end
        local last=floor
        for distance=math.min(1.5,delta.Magnitude),delta.Magnitude+1.49,1.5 do
            local q=a+delta.Unit*math.min(distance,delta.Magnitude)
            local land=floorAt(Vector3.new(q.X,last.Y+offset,q.Z))
            if not land then API.BikeRoadIssue="No dry ground ahead" return false end
            if math.abs(land.Y-last.Y)>2.2 then API.BikeRoadIssue="Ground height change: "..tostring(land.Y-last.Y) return false end
            last=land
        end
        return true
    end
    local target=destination
    brake()
    local points=planBikeRoute(target)
    if not points then
        local origin=vehicle:GetPivot().Position
        local toward=Vector3.new(origin.X-destination.X,0,origin.Z-destination.Z)
        toward=toward.Magnitude>0.1 and toward.Unit or Vector3.xAxis
        for _,distance in ipairs({18,32}) do
            for _,angle in ipairs({0,45,-45,90,-90}) do
                local candidate=destination+CFrame.Angles(0,math.rad(angle),0):VectorToWorldSpace(toward)*distance
                local floor=floorAt(candidate)
                if floor then
                    candidate=Vector3.new(candidate.X,floor.Y+3,candidate.Z)
                    points=planBikeRoute(candidate)
                    if points then target=candidate break end
                end
            end
            if points then break end
        end
    end
    if not points then API.LastTransportError="No safe bike route" cleanup() return false end
    status(owned.name.." - following planned ground route")
    logEvent("MOVE","Bike route: "..#points.." waypoints")
    API.BikeRouteWaypoints=#points
    local index,replans,localDetours=1,0,0
    local arrived=false
    local tripDeadline=os.clock()+math.max(45,(root.Position-target).Magnitude/10+30)
    local lastProgress,lastPosition=os.clock(),vehicle:GetPivot().Position
    local visits={}
    while alive(token) and seat.Parent and h.SeatPart==seat and index<=#points do
        local position=vehicle:GetPivot().Position
        if not validWorldPosition(position) then API.LastTransportError="Vehicle despawned or left valid world" break end
        if Vector3.new(destination.X-position.X,0,destination.Z-position.Z).Magnitude<Config.BikeFinalApproach then arrived=true break end
        if os.clock()>tripDeadline then API.LastTransportError="Bike route timed out" break end
        local point=points[index]
        API.BikeWaypoint=tostring(point)
        local delta=Vector3.new(point.X-position.X,0,point.Z-position.Z)
        if delta.Magnitude<1.6 then index+=1 continue end
        if (position-lastPosition).Magnitude>1 then lastProgress,lastPosition=os.clock(),position end
        local direction=delta.Unit
        local speed=Config.VehicleSpeed
        if index<#points then
            local turn=Vector3.new(points[index+1].X-point.X,0,points[index+1].Z-point.Z)
            if turn.Magnitude>0.1 and direction:Dot(turn.Unit)<0.8 and delta.Magnitude<8 then speed=Config.BikeTurnSpeed end
        end
        local ahead=position+direction*math.min(delta.Magnitude,math.max(3,speed*0.18))
        if not clearDrive(position,ahead) or os.clock()-lastProgress>1.2 then
            brake()
            local skip
            for future=math.min(index+6,#points),index+1,-1 do
                if clearDrive(position,points[future]) then skip=future break end
            end
            if skip then index=skip continue end
            local bypass,score
            local goalIndex=math.min(index+3,#points)
            local goal=points[goalIndex]
            if os.clock()-lastProgress<=1.2 and localDetours<6 then
                for _,length in ipairs({6,10}) do
                    for _,angle in ipairs({40,-40,75,-75,110,-110}) do
                        local candidate=position+CFrame.Angles(0,math.rad(angle),0):VectorToWorldSpace(direction)*length
                        local key=math.floor(candidate.X/5)..":"..math.floor(candidate.Z/5)
                        local cost=(candidate-goal).Magnitude+math.abs(angle)*0.025+(visits[key] or 0)*12
                        if (not score or cost<score) and clearDrive(position,candidate) and clearDrive(candidate,goal) then bypass,score=candidate,cost end
                    end
                end
            end
            if bypass then
                local key=math.floor(bypass.X/5)..":"..math.floor(bypass.Z/5)
                visits[key]=(visits[key] or 0)+1
                for _=index,goalIndex-1 do table.remove(points,index) end
                table.insert(points,index,bypass)
                localDetours+=1
                API.BikeDetours=(API.BikeDetours or 0)+1
                logEvent("MOVE","Bike steering around obstacle","bike-detour",1)
            else
                replans+=1
                API.BikeReplans=(API.BikeReplans or 0)+1
                if replans>Config.BikeMaxReplans then API.LastTransportError="Bike detour attempts exhausted" break end
                local revised=planBikeRoute(target)
                if not revised then API.LastTransportError="Bike route became blocked" break end
                points,index=revised,1
                localDetours=0
                lastProgress,lastPosition=os.clock(),position
                logEvent("MOVE","Replanning bike route; attempt "..replans)
            end
            task.wait(0.05)
            continue
        end
        local dt=math.min(RunService.Heartbeat:Wait(),0.05)
        if not alive(token) or h.SeatPart~=seat then break end
        local step=position+direction*math.min(speed*dt,delta.Magnitude)
        local floor=floorAt(step)
        if not floor then API.LastTransportError="Bike reached edge of dry ground" break end
        local grounded=Vector3.new(step.X,floor.Y+offset,step.Z)
        vehicle:PivotTo(CFrame.lookAt(grounded,grounded+direction))
        brake()
        API.VehicleLocation={Guid=owned.guid,Position=tostring(seat.Position),Distance=(seat.Position-root.Position).Magnitude}
    end
    if alive(token) and h.SeatPart==seat and (arrived or index>#points) then
        API.BikeRoutesCompleted=(API.BikeRoutesCompleted or 0)+1
        API.LastTransportError=nil
        API.TransportTripResult="Arrived"
        logEvent("MOVE","Bike route complete; walking final approach")
    end
    cleanup()
    task.wait(0.5)
    stepOutOfCar()
    -- Walk/run the final approach; never drive through shop interiors or into water.
    return false
end
local leaveFishBuyer,leaveHardware,leaveCarDealer
local function inBikeShop(point)
    return point.X>235 and point.X<276 and point.Z<-236 and point.Z>-292
end
local function crossBikeDoor(token,entering)
    local _,h,root=character()
    if not h or not root then return false end
    local target=Vector3.new(250.91,255.2,entering and -245 or -225)
    status(entering and "Entering bike shop through public door" or "Exiting bike shop before spawning transport")
    local deadline=os.clock()+8
    repeat
        updateTravelSprint()
        h:MoveTo(target)
        local delta=root.Position-target
        if Vector3.new(delta.X,0,delta.Z).Magnitude<3 and math.abs(delta.Y)<4 then Sprint.sprinting.set(false) return true end
        task.wait(Config.ObstaclePollInterval)
    until not alive(token) or h.Health<=0 or os.clock()>deadline
    Sprint.sprinting.set(false)
    return false
end
local function leaveBikeShop(token)
    local _,_,root=character()
    if not root then return false end
    if not walkingRoute(token,Vector3.new(243,255.2,root.Position.Z),"Following bike shop display aisle") then return false end
    if not walkingRoute(token,Vector3.new(243,255.2,-245),"Approaching bike shop exit aisle") then return false end
    if not walkingRoute(token,Vector3.new(250.91,255.2,-245),"Approaching bike shop door") then return false end
    return crossBikeDoor(token,false)
end
walkToSpot = function(token,destination,caption)
    destination=destination or API.Spot
    local _,_,travelRoot=character()
    API.Travelling=true
    if travelRoot and inBikeShop(travelRoot.Position) and not inBikeShop(destination) then
        if not leaveBikeShop(token) then return false,"Could not exit bike shop through its door" end
    end
    if leaveHardware and travelRoot then
        local function insideHardware(point)
            return point.X>-170 and point.X<-98 and point.Z>96 and point.Z<174
        end
        if insideHardware(travelRoot.Position) and not insideHardware(destination) then
            if not leaveHardware(token) then return false,"Could not exit hardware through its door" end
        end
    end
    local function inFishShop(point)
        return point.X>-288 and point.X<-236 and point.Z>330 and point.Z<412 and point.Y>248 and point.Y<263
    end
    if leaveFishBuyer and travelRoot and inFishShop(travelRoot.Position) and not inFishShop(destination) then
        if not leaveFishBuyer(token) then return false,"Could not exit fish shop" end
    end
    local function inDealer(p)
        return p.X>55 and p.X<165 and p.Z>476 and p.Z<580 and p.Y>248 and p.Y<263
    end
    if leaveCarDealer and travelRoot and inDealer(travelRoot.Position) and not inDealer(destination) then
        if not leaveCarDealer(token) then return false,"Could not exit car dealership" end
    end
    if skyTravel then
        local handled,reached,why=skyTravel(token,destination)
        if handled then return reached,why end
    end
    if lakeTravel then
        local handled,reached,why=lakeTravel(token,destination)
        if handled then return reached,why end
    end
    API.Travelling = true
    local ok, reached, reason = pcall(function()
        local mainland=Vector3.new(950,255.3,600)
        local function crossWater(target)
            local _,hum,root=character()
            local deadline=os.clock()+math.max(60,(root.Position-target).Magnitude/7+40)
            local previous,bestProgress=root.Position,os.clock()
            API.Transport="Swimming"
            updateSwimmingSprint()
            while alive(token) and (Vector3.new(root.Position.X-target.X,0,root.Position.Z-target.Z)).Magnitude>5 do
                status("Crossing to/from Deep Sea Island")
                updateSwimmingSprint()
                hum:MoveTo(target)
                if (root.Position-previous).Magnitude>3 then previous,bestProgress=root.Position,os.clock() end
                if hum.Health<=0 or os.clock()>deadline or os.clock()-bestProgress>15 then Sprint.sprinting.set(false) return false,"Island crossing blocked" end
                task.wait(0.4)
            end
            Sprint.sprinting.set(false)
            return alive(token)
        end
        if API.OnIsland and (API.ZoneSkill~="DeepSeaIsland" or destination~=API.Spot) then
            local crossed,why=crossWater(mainland)
            if not crossed then return false,why end
            API.OnIsland=false
        end
        if API.ZoneSkill=="DeepSeaIsland" and destination==API.Spot then
            if not API.OnIsland then
                tryOwnedTransport(token,mainland)
                if not alive(token) then return false end
                local _,islandVehicleType=ownedTravelVehicle()
                local _,_,islandRoadRoot=character()
                if islandVehicleType and API.TransportTripResult~="Arrived" and islandRoadRoot and (islandRoadRoot.Position-mainland).Magnitude>8 then
                    return false,API.LastTransportError or "Waiting for owned transport to reach island crossing"
                end
                local approached,why=walkingRoute(token,mainland,"Running to island crossing")
                if not approached then return false,why end
                local crossed,warning=crossWater(destination)
                if not crossed then return false,warning end
                API.OnIsland=true
            end
            return walkingRoute(token,destination,caption)
        end
        if tryOwnedTransport(token,destination) then return true end
        local attempted=API.SelectedVehicle and API.SelectedVehicle.Guid
        local alternate,alternateType=ownedTravelVehicle()
        if alternateType=="car" and alternate.guid~=attempted and API.TransportTripResult~="Arrived" and API.TransportTripResult~="Indoor" then
            logEvent("MOVE","Trying alternate owned car: "..alternate.name)
            if tryOwnedTransport(token,destination) then return true end
        end
        local _,preferredType=ownedTravelVehicle()
        local _,_,afterTransportRoot=character()
        if preferredType and API.TransportTripResult~="Indoor" and API.TransportTripResult~="Arrived" and afterTransportRoot
            and (afterTransportRoot.Position-destination).Magnitude>8 then
            return false,API.LastTransportError or "Waiting for owned transport; walking fallback disabled"
        end
        API.Transport="Running"
        local _,_,roadRoot=character()
        if roadRoot and (roadRoot.Position-destination).Magnitude>Config.FootRoadDistance then
            local route=roadRoute(roadRoot.Position,destination)
            for _,junction in ipairs(route) do
                if not alive(token) then return false end
                local target=Vector3.new(junction.X,255.2,junction.Z)
                if (roadRoot.Position-target).Magnitude>8 then
                    local arrived=walkingRoute(token,target,"Running along city streets")
                    if not arrived then return false,"Street approach blocked" end
                end
            end
        end
        return walkingRoute(token,destination,caption)
    end)
    API.Travelling = false
    Sprint.sprinting.set(false)
    if not ok then error(reached) end
    return reached, reason
end

local function equipRod()
    local c, h = character()
    if not c or not h then return nil end
    local best, bestLevel = nil, -1
    local function findPhysicalRod()
        for _, container in ipairs({c, player.Backpack}) do
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") and (tool:GetAttribute("FishingItem") == "rod" or tool:HasTag("FishingRod")) then
                    local info=Items.get_item_info(Data,tool:GetAttribute("ItemGUID"))
                    local name=info and info.name or tool.Name
                    local level = Skills.get_level_for_skill("fishing", name)
                    if level <= API.Level and level > bestLevel then best, bestLevel = tool, level end
                end
            end
        end
    end
    findPhysicalRod()
    local inventoryRod,inventoryLevel=nil,-1
    Items.iterate_through_items_of_type(Data,"rod",function(item)
        local level=Skills.get_level_for_skill("fishing",item.name)
        if item.location=="hand" and (not item.durability or item.durability>0) and level<=API.Level and level>inventoryLevel then inventoryRod,inventoryLevel=item,level end
    end)
    if inventoryRod and inventoryLevel>bestLevel then
        local accepted,reason=netGet("toggle_equip_item",inventoryRod.guid)
        if not accepted then API.LastWarning="Rod equip request rejected: "..tostring(reason) end
        local deadline=os.clock()+3
        repeat
            findPhysicalRod()
            if best and bestLevel>=inventoryLevel then break end
            task.wait(0.1)
        until os.clock()>deadline or not API.Running
    end
    if best and best.Parent ~= c then h:EquipTool(best) task.wait(0.3) end
    return best
end

local function loadBait(tool)
    local info = Items.get_item_info(Data, tool:GetAttribute("ItemGUID"))
    if not info then return false, "Rod inventory data unavailable" end
    local bait
    Items.iterate_through_items_of_type(Data, "ammo", function(item)
        if item.location == "hand" and item.amount > 0 and item.class.name == API.BaitAmmo then
            bait = item
        end
    end)
    if not bait then return false, "No compatible unlocked bait available" end
    local amount, kind = netGet("equip_ammo_on_item", tool:GetAttribute("ItemGUID"), bait.guid)
    if type(amount) ~= "number" or amount <= 0 then return false, "Could not equip bait" end
    info.ammo_amount, info.override_ammo_type = amount, kind
    return true
end

local function cash() return math.floor(Data.money and Data.money.hand or 0) end
local function bank() return math.floor(Data.money and Data.money.bank or 0) end
local function waitFor(token, predicate, timeout)
    local deadline = os.clock() + (timeout or 4)
    repeat
        if predicate() then return true end
        task.wait(0.1)
    until not alive(token) or os.clock() >= deadline
    return predicate()
end
local function updateProgress()
    API.Level = XP.xp_to_level(Data.xp and Data.xp.fishing or 1)
    API.FishingXP = Data.xp and Data.xp.fishing or 1
    local nextUnlock
    for _, unlock in ipairs(Unlocks) do
        if unlock.level > API.Level and (not nextUnlock or unlock.level < nextUnlock.level) then nextUnlock = unlock end
    end
    API.NextUnlock = nextUnlock and {Name = nextUnlock.display_name, Level = nextUnlock.level} or nil
end
local capacity, capacityAt = nil, 0
local function inventoryFull(refresh)
    if refresh or not capacity or os.clock() - capacityAt > 10 then
        local result = netGet("get_max_inventory_space")
        if type(result) ~= "table" or type(result.hand) ~= "number" then error("Could not read server inventory capacity") end
        capacity, capacityAt = result.hand, os.clock()
    end
    return Items.get_inventory_count(Data).hand >= capacity
end
local function fishCount()
    local total = 0
    Items.iterate_through_items_of_type(Data, "fish", function(item)
        if item.location == "hand" then total += item.amount or 1 end
    end)
    return total
end
local function moveTo(token, position, caption)
    local ok, reason = walkToSpot(token, position, caption)
    if not ok and alive(token) then error(reason or "Travel failed") end
    return ok and alive(token)
end
local function transfer(token, from, to, amount)
    if not alive(token) or amount <= 0 then return false end
    if API.AtSkyFishing and skyTravel then
        local handled,reached,why=skyTravel(token,API.Shore)
        if handled and not reached then error(why or "Sky landing before banking failed") end
        if not alive(token) then return false end
    end
    local beforeHand, beforeBank = cash(), bank()
    status((from == "hand" and "Depositing $" or "Withdrawing purchase shortfall $") .. amount)
    local accepted, rejection = netGet("transfer_funds", from, to, amount)
    if not accepted and alive(token) then
        local c,h,root = character()
        local candidates={}
        for _, atm in ipairs(Collection:GetTagged("ATM")) do
            if atm:IsDescendantOf(workspace) then
                local prompt=atm:FindFirstChildWhichIsA("ProximityPrompt",true)
                local position = prompt and (prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or prompt.Parent.Position) or atm:GetPivot().Position
                local delta = (position - root.Position).Magnitude
                if prompt and prompt.Enabled and delta<1500 then
                    local params=RaycastParams.new()
                    params.FilterType=Enum.RaycastFilterType.Exclude
                    params.FilterDescendantsInstances={c,atm}
                    params.RespectCanCollide=true
                    local best
                    -- Approach on solid ground within transfer range. A fixed +Z
                    -- offset can put the destination behind the ATM's building.
                    for i=0,7 do
                        local angle=i*math.pi/4
                        local point=position+Vector3.new(math.cos(angle)*8,0,math.sin(angle)*8)
                        local floor=workspace:Raycast(point+Vector3.new(0,6,0),Vector3.new(0,-24,0),params)
                        if floor and floor.Material~=Enum.Material.Water and floor.Normal.Y>0.6 then
                            local stand=Vector3.new(point.X,floor.Position.Y+h.HipHeight+root.Size.Y/2,point.Z)
                            if math.abs(stand.Y-root.Position.Y)<8 then
                                local blocked=workspace:Raycast(root.Position,stand-root.Position,params)
                                    or workspace:Raycast(root.Position-Vector3.new(0,1.7,0),stand-root.Position,params)
                                local score=(stand-root.Position).Magnitude+(blocked and 300 or 0)
                                if not best or score<best.Score then best={Position=stand,ATMPosition=position,Score=score} end
                            end
                        end
                    end
                    if best then table.insert(candidates,best) end
                end
            end
        end
        table.sort(candidates,function(a,b)return a.Score<b.Score end)
        if #candidates==0 then error("Bank transfer rejected; no accessible ATM approach found") end
        for index,candidate in ipairs(candidates) do
            if index>3 or accepted or not alive(token) then break end
            API.ATMTarget=tostring(candidate.ATMPosition)
            local approached=walkToSpot(token,candidate.Position,"Approaching an accessible ATM")
            if not alive(token) then return false end
            API.LastATMApproachCompleted=approached
            if (root.Position-candidate.ATMPosition).Magnitude<18 then
                accepted,rejection=netGet("transfer_funds",from,to,amount)
                if not accepted then
                    task.wait(0.5)
                    if not alive(token) then return false end
                    accepted,rejection=netGet("transfer_funds",from,to,amount)
                end
            end
        end
    end
    if not accepted then error("Server rejected bank transfer: "..tostring(rejection)) end
    local confirmed = waitFor(token, function()
        -- A job can pay again while this transfer is being replicated; confirm the bank credit.
        if from == "hand" then return bank() >= beforeBank + amount end
        return cash() >= beforeHand + amount and bank() <= beforeBank - amount
    end)
    if not confirmed then error("Bank transfer was not confirmed by server data") end
    if from == "hand" then API.Deposited += amount else API.Withdrawn += amount end
    updateProgress()
    return true
end
local function deposit(token)
    if cash()>=Config.DepositThreshold and os.clock()>=(API.NextDepositAttempt or 0) then
        local ok,result=pcall(transfer,token,"hand","bank",cash())
        if not alive(token) then return false end
        if ok and result then API.NextDepositAttempt=nil return true end
        API.LastWarning="Deposit deferred: "..tostring(ok and "not confirmed" or result)
        API.NextDepositAttempt=os.clock()+30
        status("ATM unavailable - retrying deposit in 30 seconds")
    end
    return true
end
local lootRetry=setmetatable({},{__mode="k"})
local function dropPosition(drop)
    local zone=drop:FindFirstChild("PickUpZone")
    if zone and zone:IsA("BasePart") then return zone.Position end
    if drop:IsA("Model") then return drop:GetPivot().Position end
    if drop:IsA("BasePart") then return drop.Position end
end
local function collectDrops(token,center,radius)
    if not Config.AutoPickupDrops or player:GetAttribute("IsInPassiveMode") then return true end
    local folder=workspace:FindFirstChild("DroppedItems")
    if not folder then return true end
    local picked=0
    local deadline=os.clock()+40
    while alive(token) and picked<12 and os.clock()<deadline do
        local _,hum,root=character()
        if not root or not hum or hum.Health<=0 then return false end
        local target,position,distance
        for _,drop in ipairs(folder:GetChildren()) do
            if drop:GetAttribute("Locked")~=true and os.clock()-(lootRetry[drop] or -math.huge)>30 then
                local p=dropPosition(drop)
                local isMoney=drop:GetAttribute("item_type")=="money"
                local enoughSpace=isMoney or (not inventoryFull() and Items.get_inventory_count(Data).hand<capacity-Config.LootReserveSlots)
                if p and enoughSpace and (p-center).Magnitude<=radius then
                    local delta=(root.Position-p).Magnitude
                    if not distance or delta<distance then target,position,distance=drop,p,delta end
                end
            end
        end
        if not target then break end
        lootRetry[target]=os.clock()
        local beforeCount=Items.get_inventory_count(Data).hand
        local beforeMoney=cash()+bank()
        local _,h=character()
        if h then h:UnequipTools() end
        local reached=walkToSpot(token,position,"Collecting dropped "..target.Name)
        if not alive(token) then return false end
        local accepted,reason
        if target.Parent and reached then accepted,reason=netGet("pickup_dropped_item",target) end
        API.LastLootReply={Accepted=accepted,Reason=reason,Item=target.Name}
        local confirmed=waitFor(token,function()
            return Items.get_inventory_count(Data).hand>beforeCount or cash()+bank()>beforeMoney
        end,accepted and 3 or 0.3)
        if confirmed then API.DropsCollected=(API.DropsCollected or 0)+1 end
        picked+=1
        if reason=="NoSpace" then break end
    end
    return alive(token)
end
local function recoverDeathDrops(token)
    local record=API.DeathRecovery
    if not record then return true end
    if not Config.RecoverDeathDrops or not Config.AutoPickupDrops or record.JobId~=game.JobId
        or os.time()-record.Time>Config.DeathLootExpiry then
        API.DeathRecovery=nil
        env.BlockSpinDeathRecovery=nil
        return true
    end
    status("Returning to recover death drops")
    player:RequestStreamAroundAsync(record.Position,5)
    if not alive(token) then return false end
    local recoveryOK=walkToSpot(token,record.Position,"Returning to death location")
    if not alive(token) then return false end
    if recoveryOK then
        -- Newly dropped items can remain locked briefly; respect that lock.
        waitFor(token,function()
            local folder=workspace:FindFirstChild("DroppedItems")
            if not folder then return true end
            for _,drop in ipairs(folder:GetChildren()) do
                local p=dropPosition(drop)
                if p and (p-record.Position).Magnitude<35 and drop:GetAttribute("Locked")==true then return false end
            end
            return true
        end,5)
        if not alive(token) then return false end
        if not collectDrops(token,record.Position,35) then return false end
        API.DeathRecoveries=(API.DeathRecoveries or 0)+1
    else
        API.LastWarning="Could not reach death drops; resuming normal work"
    end
    -- Keep a newer death record if another death occurred during recovery.
    if API.DeathRecovery==record then API.DeathRecovery=nil env.BlockSpinDeathRecovery=nil end
    return alive(token)
end
local bikeOfferCache
local function bikeOffer(token)
    if bikeOfferCache and bikeOfferCache.Option:IsDescendantOf(workspace)
        and os.clock()-bikeOfferCache.Time<30 then
        return bikeOfferCache.Crate,bikeOfferCache.Option,bikeOfferCache.Price
    end
    player:RequestStreamAroundAsync(Vector3.new(235.03,254.20,-252.75),4)
    if not alive(token) then return nil end
    local tile=workspace.Map.Tiles:FindFirstChild("BurgerPlaceTile")
    local shop=tile and tile:FindFirstChild("UrbanCyclesAndSkates")
    local interior=shop and shop:FindFirstChild("Interior")
    local crates=interior and interior:FindFirstChild("Crates")
    local crate=crates and crates:FindFirstChild("Bike Crate")
    local options=crate and crate:FindFirstChild("CrateOptions")
    local chosen,price
    if options then
        for _,option in ipairs(options:GetChildren()) do
            if option:IsA("ModuleScript") and option:GetAttribute("disabled")~=true then
                local ok,definition=pcall(require,option)
                local cost=option:GetAttribute("price")
                if ok and type(cost)=="number" and cost>0 and (not definition.purchase_type or definition.purchase_type=="money") then
                    local valid=#(definition.items or {})>0
                    for _,item in ipairs(entries) do
                        if item.item_type~="bike" or (item.name~="BMX" and item.name~="EScooter") then valid=false end
                    end
                    if valid and (not price or cost<price) then chosen,price=option,cost end
                end
            end
        end
    end
    if chosen then bikeOfferCache={Crate=crate,Option=chosen,Price=price,Time=os.clock()} end
    return crate,chosen,price
end
local function ensureBike(token)
    if not Config.AutoBuyBike or ownedTravelVehicle() then return true end
    if os.clock()-(API.LastBikePurchaseAttempt or -math.huge)<60 then
        API.BikePurchaseStatus="Waiting for bike purchase retry cooldown"
        return true
    end
    local crate,chosen,price=bikeOffer(token)
    if not chosen then API.BikePurchaseStatus="Bike case not streamed" return true end
    if cash()+bank()<price+Config.BikePurchaseReserve then API.BikePurchaseStatus="Saving for basic bike case" return true end
    if inventoryFull() then API.BikePurchaseStatus="No inventory space for bike" return true end
    if cash()<price and not Config.AllowPurchaseWithdrawals then return true end
    if cash()<price and not transfer(token,"bank","hand",price-cash()) then return false end
    local outside=Vector3.new(250.91,255.2,-225)
    local inside=Vector3.new(250.91,255.2,-245)
    local _,_,root=character()
    if not root then return false end
    local p=root.Position
    local inShop=inBikeShop(p)
    if not inShop then
        -- The west wall/display cannot be crossed diagonally from the street.
        if p.X<235 and p.Z<-230 and p.Z>-320 then
            if not moveTo(token,Vector3.new(222,255.2,p.Z),"Following bike shop exterior") then return false end
            if not moveTo(token,Vector3.new(222,255.2,-225),"Going around bike shop wall") then return false end
        end
        if not moveTo(token,outside,"Travelling to bike shop entrance") then return false end
        if not crossBikeDoor(token,true) then return false end
    end
    local beacon=crate:FindFirstChild("Beacon")
    local touch=beacon and beacon:FindFirstChild("TouchPart")
    if not touch or not touch:IsA("BasePart") then error("Bike crate interaction beacon not available") end
    API.BikeShopTarget=tostring(touch.Position)
    API.BikePurchaseStatus="Approaching bike case interaction point"
    logEvent("BUY","Bike case interaction point: "..tostring(touch.Position))
    if not moveTo(token,touch.Position,"Approaching bike case interaction point") then return false end
    API.LastBikePurchaseAttempt=os.clock()
    local accepted,reason=netGet("open_crate",chosen,"money")
    logEvent("BUY","Bike case request: "..tostring(accepted~=false and accepted~=nil).."; price="..price.."; reason="..tostring(reason))
    API.LastBikePurchaseReply={Accepted=accepted~=false and accepted~=nil,Reason=reason,Price=price}
    if accepted then
        if waitFor(token,function()return ownedTravelVehicle()~=nil end,8) then
            API.BikesPurchased=(API.BikesPurchased or 0)+1
            API.BikePurchaseStatus="Owned: "..ownedTravelVehicle().name
            logEvent("BUY","Bike confirmed in inventory: "..ownedTravelVehicle().name)
        else API.LastWarning="Bike purchase was accepted but inventory confirmation is pending" end
    else API.BikePurchaseStatus="Purchase rejected: "..tostring(reason) end
    if not alive(token) then return false end
    if not moveTo(token,inside,"Leaving bike shop") then return false end
    return moveTo(token,outside,"Exiting bike shop")
end
-- The mainland buyer is indoors; enter through the south double door.
local function crossCarDealerDoor(token,entering)
    local _,hum,root=character()
    if not hum or not root then return false end
    local target=Vector3.new(122.35,255.2,entering and 484 or 440)
    status(entering and "Entering car dealership through front door" or "Leaving car dealership through front door")
    local deadline=os.clock()+8
    repeat
        if not alive(token) or hum.Health<=0 then break end
        updateTravelSprint()
        hum:MoveTo(target)
        local delta=root.Position-target
        if Vector3.new(delta.X,0,delta.Z).Magnitude<2.5 and math.abs(delta.Y)<4 then Sprint.sprinting.set(false) return true end
        task.wait(Config.ObstaclePollInterval)
    until os.clock()>deadline
    Sprint.sprinting.set(false)
    if alive(token) then error("Car dealership front door is blocked") end
    return false
end
leaveCarDealer=function(token)
    if not walkingRoute(token,Vector3.new(122.35,255.2,484),"Approaching car dealership exit") then return false end
    return crossCarDealerDoor(token,false)
end
local function hasUsableCar()
    local found
    Items.iterate_through_items_of_type(Data,"car",function(item)
        if item.location=="hand" and not item.destroyed and (item.health or 1)>0 then found=item end
    end)
    return found
end
local function gainedCrateVehicle(before)
    local award,kind
    for _,itemType in ipairs({"car","bike"}) do
        Items.iterate_through_items_of_type(Data,itemType,function(item)
            if item.location=="hand" and not before[item.guid] then award,kind=item,itemType end
        end)
        if award then return award,kind end
    end
end
local carCrateCache,carCrateScanAt
local function findCarCrate(token)
    if carCrateCache and carCrateCache.Option:IsDescendantOf(workspace) and carCrateCache.Touch:IsDescendantOf(workspace)
        and carCrateCache.Option:GetAttribute("disabled")~=true and os.clock()-carCrateCache.Time<30 then return carCrateCache end
    if carCrateScanAt and os.clock()-carCrateScanAt<30 then return nil end
    carCrateScanAt=os.clock()
    local function scan()
        local best
        local tiles=workspace.Map:FindFirstChild("Tiles")
        local tile=tiles and tiles:FindFirstChild("PrestigeDealerAndHousing")
        local dealer=tile and tile:FindFirstChild("PrestigeCarDealer")
        if not dealer then return nil end
        for _,folder in ipairs(dealer:QueryDescendants("#CrateOptions")) do
            local crate=folder.Parent
            local beacon=crate:FindFirstChild("Beacon")
            local touch=beacon and beacon:FindFirstChild("TouchPart")
            if touch and touch:IsA("BasePart") then
                for _,option in ipairs(folder:GetChildren()) do
                    local cost=option:GetAttribute("price")
                    if option:IsA("ModuleScript") and option:GetAttribute("disabled")~=true and type(cost)=="number" and cost>0 then
                        local ok,definition=pcall(require,option)
                        if ok and type(definition)=="table" and (not definition.purchase_type or definition.purchase_type=="money") then
                            local entries=type(definition.items)=="table" and definition.items or {}
                            local allVehicles=#entries>0
                            local hasCar=false
                            for _,item in ipairs(entries) do
                                if type(item)~="table" or (item.item_type~="car" and item.item_type~="bike") then allVehicles=false break end
                                if item.item_type=="car" then hasCar=true end
                            end
                            if allVehicles and hasCar and (not best or cost<best.Price) then
                                best={Crate=crate,Option=option,Touch=touch,Price=cost,Time=os.clock()}
                            end
                        end
                    end
                end
            end
        end
        return best
    end
    local offer=scan()
    if not offer then
        -- Stream named dealership tiles without moving the character.
        local tiles=workspace.Map:FindFirstChild("Tiles")
        if tiles then
            for _,tile in ipairs(tiles:GetChildren()) do
                local name=tile.Name:lower()
                if tile:IsA("Model") and (name:find("dealer") or name:find("vehicle") or name:find("carshop") or name:find("showroom")) then
                    if not alive(token) then return nil end
                    pcall(function()player:RequestStreamAroundAsync(tile:GetPivot().Position,2)end)
                end
            end
            offer=scan()
        end
    end
    carCrateCache=offer
    return offer
end
local function ensureCarCrate(token)
    if not Config.AutoBuyCarCrate then return true end
    local car=hasUsableCar()
    if car then
        API.CarCrateStatus="Owned: "..car.name
        env.BlockSpinCarCratePending=nil
        return true
    end
    local pending=env.BlockSpinCarCratePending
    if pending and pending.JobId==game.JobId then
        local award,kind=gainedCrateVehicle(pending.Before or {})
        if not award then API.CarCrateStatus="Waiting for crate inventory confirmation; no second purchase" return true end
        env.BlockSpinCarCratePending=nil
        API.NextCarCrateAttempt=os.clock()+Config.CarCrateRetryDelay
        API.CarCrateStatus="Crate awarded "..kind..": "..award.name
        return true
    end
    if os.clock()<(API.NextCarCrateAttempt or 0) then return true end
    local offer=findCarCrate(token)
    if not alive(token) then return false end
    if not offer then API.CarCrateStatus="Car crate not streamed; checking again later" return true end
    local price=offer.Price
    API.CarCratePrice=price
    local funds=cash()+(Config.AllowPurchaseWithdrawals and bank() or 0)
    if funds<price+Config.CarCrateReserve then
        API.CarCrateStatus="Saving for car crate: $"..funds.." / $"..(price+Config.CarCrateReserve)
        return true
    end
    if inventoryFull(true) then API.CarCrateStatus="Waiting for inventory space before car crate" return true end
    API.NextCarCrateAttempt=os.clock()+Config.CarCrateRetryDelay
    if cash()<price and not transfer(token,"bank","hand",price-cash()) then return false end
    API.CarCrateStatus="Travelling to car crate"
    logEvent("BUY","Car crate selected: "..offer.Crate.Name.." / "..offer.Option.Name.."; $"..price)
    local _,_,crateRoot=character()
    if not crateRoot then return false end
    local p=crateRoot.Position
    local inDealer=p.X>55 and p.X<165 and p.Z>476 and p.Z<580 and p.Y>248 and p.Y<263
    if not inDealer then
        if not moveTo(token,Vector3.new(122.35,255.2,440),"Travelling to public car dealership entrance") then return false end
        if not crossCarDealerDoor(token,true) then return false end
    end
    if not walkingRoute(token,offer.Touch.Position,"Approaching car crate interaction point") then return false end
    if not alive(token) then return false end
    if not offer.Option:IsDescendantOf(workspace) or offer.Option:GetAttribute("disabled")==true or offer.Option:GetAttribute("price")~=price then
        carCrateCache=nil
        API.CarCrateStatus="Car crate changed; checking price again"
        return true
    end
    if hasUsableCar() then return true end
    if cash()<price or inventoryFull(true) then API.CarCrateStatus="Funds or inventory changed before purchase" return true end
    local _,_,root=character()
    if not root or (root.Position-offer.Touch.Position).Magnitude>math.max(10,offer.Touch.Size.Magnitude/2+3) then
        API.CarCrateStatus="Not within car crate interaction range"
        return true
    end
    local before={}
    for _,kind in ipairs({"car","bike"}) do Items.iterate_through_items_of_type(Data,kind,function(item)before[item.guid]=true end) end
    local accepted,reason=netGet("open_crate",offer.Option,"money")
    API.LastCarCrateReply={Accepted=accepted~=nil and accepted~=false,Reason=reason,Price=price}
    if not accepted then
        API.CarCrateStatus="Car crate rejected: "..tostring(reason)
        logEvent("WARN",API.CarCrateStatus)
        return leaveCarDealer(token)
    end
    env.BlockSpinCarCratePending={JobId=game.JobId,Price=price,Time=os.clock(),Before=before}
    if not waitFor(token,function()return gainedCrateVehicle(before)~=nil end,8) then
        API.CarCrateStatus="Purchase accepted; awaiting vehicle in inventory"
        return alive(token) and leaveCarDealer(token)
    end
    local award,awardType=gainedCrateVehicle(before)
    API.LastCarCrateAward={Name=award.name,Type=awardType,Guid=award.guid}
    car=hasUsableCar()
    env.BlockSpinCarCratePending=nil
    API.CarCratesPurchased=(API.CarCratesPurchased or 0)+1
    if not car then
        API.CarCrateStatus="Crate awarded "..awardType..": "..award.name.."; retrying for car when funds allow"
        logEvent("BUY",API.CarCrateStatus)
        return leaveCarDealer(token)
    end
    API.CarCrateStatus="Owned: "..car.name
    API.ZoneSkill=nil
    API.LastSkyMode=nil
    API.NextCarCrateAttempt=nil
    logEvent("BUY","Car confirmed in inventory: "..car.name.."; car transport and Sky Fishing now available")
    return leaveCarDealer(token)
end
local buyerOutside=Vector3.new(-271.01,255.2,430)
local buyerInside=Vector3.new(-271.01,255.2,402)
local function crossBuyerDoor(token,entering)
    -- Doors need physical contact before their native ownership/push handler runs.
    -- Give that handler time instead of treating the closed door as a stuck wall.
    local approach=entering and Vector3.new(-271.01,255.2,422) or buyerInside
    if not moveTo(token,approach,entering and "Approaching fish shop door" or "Approaching shop exit") then return false end
    local _,h,root=character()
    if not h or not root then return false end
    local target=entering and buyerInside or buyerOutside
    h:MoveTo(target)
    local deadline=os.clock()+8
    while alive(token) and h.Health>0 and os.clock()<deadline do
        updateTravelSprint()
        local delta=root.Position-target
        if Vector3.new(delta.X,0,delta.Z).Magnitude<3 and math.abs(delta.Y)<4 then Sprint.sprinting.set(false) return true end
        task.wait(Config.ObstaclePollInterval)
    end
    Sprint.sprinting.set(false)
    if alive(token) then error("Fish shop door did not open") end
    return false
end
local function approachFishBuyer(token,position)
    local _,_,root=character()
    if not root then return false end
    if (position-Vector3.new(-252.61,255.04,379.80)).Magnitude>80 then
        return moveTo(token,position,"Travelling to fish buyer")
    end
    local p=root.Position
    local footprint=p.X>-288 and p.X<-236 and p.Z>330 and p.Z<412
    if footprint and p.Y>position.Y+8 then
        local c,hum=character()
        local floorParams=RaycastParams.new()
        floorParams.FilterType=Enum.RaycastFilterType.Include
        floorParams.FilterDescendantsInstances={workspace.Map,workspace.Terrain}
        floorParams.RespectCanCollide=true
        local space=OverlapParams.new()
        space.FilterDescendantsInstances={c}
        space.RespectCanCollide=true
        local recovered=false
        for _,point in ipairs({Vector3.new(-219,255.2,430),Vector3.new(-294,255.2,430),Vector3.new(-219,255.2,320)}) do
            local floor=workspace:Raycast(point+Vector3.new(0,3,0),Vector3.new(0,-12,0),floorParams)
            if floor and floor.Material~=Enum.Material.Water and floor.Normal.Y>0.7 then
                local standing=floor.Position+Vector3.new(0,hum.HipHeight+root.Size.Y/2+0.1,0)
                if #workspace:GetPartBoundsInBox(CFrame.new(standing),Vector3.new(2,4.8,2),space)==0 then
                    hum:Move(Vector3.zero)
                    root.CFrame=CFrame.new(standing)*root.CFrame.Rotation
                    root.AssemblyLinearVelocity=Vector3.zero
                    API.RoofRecoveries=(API.RoofRecoveries or 0)+1
                    logEvent("MOVE","Recovered from fish shop roof to clear street entrance")
                    recovered=true
                    break
                end
            end
        end
        if not recovered then error("Fish shop roof recovery has no clear street position") end
        p=root.Position
    end
    local inside=p.X>-288 and p.X<-236 and p.Z>330 and p.Z<412 and math.abs(p.Y-position.Y)<7
    if not inside then
        if (p-position).Magnitude>150 then
            if not moveTo(token,Vector3.new(-294,255.2,430),"Travelling to fish shop street entrance") then return false end
            p=root.Position
        end
        if p.Z<428 then
            local side=p.X>-236 and -219 or -294
            if not moveTo(token,Vector3.new(side,255.2,p.Z),"Following fish shop exterior") then return false end
            if not moveTo(token,Vector3.new(side,255.2,430),"Going around fish shop") then return false end
        end
        if not moveTo(token,buyerOutside,"Approaching fish shop entrance") then return false end
        if not crossBuyerDoor(token,true) then return false end
    end
    return moveTo(token,position,"Approaching fish buyer")
end
leaveFishBuyer=function(token)
    local _,_,root=character()
    if root and root.Position.X>-288 and root.Position.X<-236 and root.Position.Z>330 and root.Position.Z<412 and root.Position.Y>248 and root.Position.Y<263 then
        if not crossBuyerDoor(token,false) then return false end
        -- Hand off to the owned vehicle as soon as we are outside the door.
        return true
    end
    return alive(token)
end
local function sellFish(token,manualRequest)
    if not alive(token) then return false end
    -- Recheck current server capacity before travelling or submitting a sale.
    if not manualRequest and not inventoryFull(true) then
        API.LastSellSkip="Inventory is not full"
        return true
    end
    API.LastSaleReason=manualRequest and "Manual request" or "Inventory full"
    local before = fishCount()
    local moneyBefore=cash()+bank()
    if before == 0 then error("Inventory full of non-fish items; clear a slot") end
    status("Going to sell fish")
    player:RequestStreamAroundAsync(Vector3.new(-252.61, 255.04, 379.80), 5)
    if not alive(token) then return false end
    local beacon
    for _, candidate in ipairs(Collection:GetTagged("SellFishBeacon")) do
        if candidate:IsDescendantOf(workspace) and not FishBuyer.is_limited_beacon(candidate) then beacon = candidate break end
    end
    local position = beacon and beacon:FindFirstChild("TouchPart") and beacon.TouchPart.Position or Vector3.new(-252.61, 255.04, 379.80)
    if not approachFishBuyer(token,position) then return false end
    local _, humanoid = character()
    if humanoid then humanoid:UnequipTools() end
    task.wait(0.5)
    if not alive(token) then return false end
    status("Selling fish")
    local accepted = netGet("sell_all_fish")
    if not accepted then error("Fish buyer rejected sale") end
    if not waitFor(token, function() return fishCount() < before end) then error("Fish sale was not confirmed") end
    if not waitFor(token,function()return cash()+bank()>moneyBefore end,8) then error("Fish removed but sale payment has not been confirmed") end
    API.Sold += before - fishCount()
    updateProgress()
    if inventoryFull() then error("Inventory still full after selling available fish") end
    if not leaveFishBuyer(token) then return false end
    return deposit(token)
end

local zones = {
    {Skill = "LilPond", Name = "Lil' Pond", Center = Vector3.new(192.29, 249.84, -765.85)},
    {Skill = "LakeOLoot", Name = "Lake O' Loot", Center = Vector3.new(832.8783, 249.84375, -968.2566)},
    {Skill = "BigCatchPier", Name = "Big Catch Pier", Center = Vector3.new(-358.09, 250.53, 808.99)},
    {Skill = "GoFishDocks", Name = "Go Fish Docks", Center = Vector3.new(182.36, 250.95, 685.20)},
}
local rejectedZones = {}
local islandAnchor, islandChecked = nil, -math.huge
local function discoverIsland()
    if Config.DeepSeaAnchor then return Config.DeepSeaAnchor end
    if os.clock()-islandChecked<90 then return islandAnchor end
    islandChecked=os.clock()
    if workspace:GetAttribute("fishing_update_2")==false then return nil end
    for _,beacon in ipairs(Collection:GetTagged("SellFishBeacon")) do
        if beacon:IsDescendantOf(workspace) and beacon:GetAttribute("IslandFishBuyer")==true then
            islandAnchor=beacon:GetPivot().Position
            return islandAnchor
        end
    end
    for _,object in ipairs(workspace.Map:QueryDescendants("Model, Folder")) do
        local name=object.Name:lower()
        if object:IsA("Model") and (name:find("deepsea",1,true) or name:find("deep sea",1,true) or name:find("island",1,true)) then
            islandAnchor=object:GetPivot().Position
            return islandAnchor
        end
    end
    -- Discover isolated, dry offshore land from streamed geometry instead of inventing island coordinates.
    local terrainParams=RaycastParams.new()
    terrainParams.FilterType=Enum.RaycastFilterType.Include
    terrainParams.FilterDescendantsInstances={workspace.Terrain}
    local landParams=RaycastParams.new()
    landParams.FilterType=Enum.RaycastFilterType.Exclude
    landParams.FilterDescendantsInstances={player.Character,workspace.Vehicles}
    landParams.RespectCanCollide=true
    local mansion=Vector3.new(968,250,300)
    for _,distance in ipairs({600,1200,2400}) do
        for _,direction in ipairs({Vector3.xAxis,Vector3.zAxis,-Vector3.xAxis,-Vector3.zAxis}) do
            local center=mansion+direction*distance
            if not (center.X>-750 and center.X<1400 and center.Z>-1400 and center.Z<900) then
                status("Locating unlocked Deep Sea Island")
                player:RequestStreamAroundAsync(center,2)
                if not API.Running then return nil end
                for _,dx in ipairs({-120,0,120}) do
                    for _,dz in ipairs({-120,0,120}) do
                        local origin=center+Vector3.new(dx,180,dz)
                        local land=workspace:Raycast(origin,Vector3.new(0,-300,0),landParams)
                        if land and land.Material~=Enum.Material.Water and land.Normal.Y>0.65 and land.Position.Y>249 then
                            local sea=workspace:Raycast(land.Position+Vector3.new(70,80,0),Vector3.new(0,-200,0),terrainParams)
                            if sea and sea.Material==Enum.Material.Water then islandAnchor=land.Position return islandAnchor end
                        end
                    end
                end
            end
        end
    end
    return nil
end
local function findShore(water)
    local c, h, root = character()
    if not root or not h then return nil end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclusions={c}
    if workspace:FindFirstChild("TerrainDecor") then exclusions[#exclusions+1]=workspace.TerrainDecor end
    params.FilterDescendantsInstances = exclusions
    params.IgnoreWater = false
    params.RespectCanCollide=true
    local terrainParams=RaycastParams.new()
    terrainParams.FilterType=Enum.RaycastFilterType.Include
    terrainParams.FilterDescendantsInstances={workspace.Terrain}
    terrainParams.IgnoreWater=false
    local candidates = {}
    for _, radius in ipairs({12,25,40,50,80,120,180,240,320}) do
        for i=0,15 do
            local angle = i*math.pi/8
            local xz = water + Vector3.new(math.cos(angle)*radius,0,math.sin(angle)*radius)
            local result = workspace:Raycast(xz+Vector3.new(0,35,0),Vector3.new(0,-70,0),params)
            if result and result.Material~=Enum.Material.Water and result.Normal.Y>0.65 and result.Position.Y>=water.Y+0.2 and result.Position.Y-water.Y<20 then
                local spot = result.Position+Vector3.new(0,h.HipHeight+root.Size.Y/2,0)
                local toward=Vector3.new(water.X-spot.X,0,water.Z-spot.Z)
                local cast
                if toward.Magnitude>0.01 then
                    for _,distance in ipairs({50,40,30,20,12}) do
                        local target=spot+toward.Unit*math.min(distance,toward.Magnitude)
                        local hit=workspace:Raycast(target+Vector3.new(0,45,0),Vector3.new(0,-100,0),terrainParams)
                        if hit and hit.Material==Enum.Material.Water then cast=hit.Position break end
                    end
                end
                if cast then candidates[#candidates+1]={spot=spot,water=cast,score=radius*100+(root.Position-spot).Magnitude*0.01} end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.score<b.score end)
    return candidates[1] and candidates[1].spot,candidates[1] and candidates[1].water
end
local function selectZone()
    local level=API.Level
    if API.LastZoneLevel~=level then table.clear(rejectedZones) API.LastZoneLevel=level end
    local chosen = zones[1]
    for _, zone in ipairs(zones) do
        if not rejectedZones[zone.Skill] and Skills.has_skill(Data, "fishing", zone.Skill) then chosen = zone end
    end
    API.DeepSeaAvailable=false
    if Config.EnableDeepSea and Skills.has_skill(Data,"fishing","FishingLicense") then
        local anchor=discoverIsland()
        API.DeepSeaAvailable=anchor~=nil
        if anchor and Data.has_fishing_license==true and not rejectedZones.DeepSeaIsland then
            chosen={Skill="DeepSeaIsland",Name="Deep Sea Island",Center=anchor}
        elseif not anchor then
            API.LastWarning="Deep Sea unlocked: island geometry not located; using highest verified mainland area"
        elseif not Data.has_fishing_license then
            API.LastWarning="Deep Sea requires the $2,500,000 fishing license"
        end
    end
    if API.ZoneSkill == chosen.Skill and API.LastCenterMode==Config.FishFromLakeCenter and API.LastSkyMode==Config.SkyFishing then return end
    player:RequestStreamAroundAsync(chosen.Center,3)
    if chosen.Skill == "LilPond" then
        API.Spot, API.Water = Vector3.new(205.97638, 254.93259, -819.11719), Vector3.new(192.29074, 249.84375, -765.84711)
    else
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = {workspace.Terrain}
        params.IgnoreWater = false
        local water
        for _, offset in ipairs({Vector3.zero, Vector3.new(25,0,0), Vector3.new(-25,0,0), Vector3.new(0,0,25), Vector3.new(0,0,-25), Vector3.new(60,0,0), Vector3.new(-60,0,0), Vector3.new(0,0,100), Vector3.new(100,0,0), Vector3.new(-100,0,0)}) do
            local result = workspace:Raycast(chosen.Center + offset + Vector3.new(0,200,0), Vector3.new(0,-500,0), params)
            if result and result.Material == Enum.Material.Water then water = result.Position break end
        end
        if not water then rejectedZones[chosen.Skill] = true return selectZone() end
        API.Water, API.Spot = water, water + Vector3.new(0, 5.1, -15)
    end
    local shore,castWater = findShore(API.Water)
    if not shore then
        if chosen.Skill == "LilPond" then error("No dry shore found within casting range") end
        rejectedZones[chosen.Skill]=true
        return selectZone()
    end
    if not API.AtLakeCenter then clearLakeSupport() end
    API.Shore=shore
    local _,travelType=ownedTravelVehicle()
    API.SkyFishing=Config.SkyFishing and travelType=="car" and chosen.Skill~="DeepSeaIsland"
    API.CenterFishing=(Config.FishFromLakeCenter or API.SkyFishing) and chosen.Skill~="DeepSeaIsland"
    API.LastCenterMode=Config.FishFromLakeCenter
    API.LastSkyMode=Config.SkyFishing
    if API.CenterFishing then
        local center=API.Water
        local _,hum,root=character()
        API.CenterWater=center
        API.Spot=center+Vector3.new(0,1.25+hum.HipHeight+root.Size.Y/2,0)
        -- Cast away from the small support, while keeping the bobber in water.
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances={workspace.Terrain}
        params.IgnoreWater=false
        local target
        for _,distance in ipairs({18,12,8}) do
            for _,direction in ipairs({Vector3.xAxis,-Vector3.xAxis,Vector3.zAxis,-Vector3.zAxis}) do
                local hit=workspace:Raycast(center+direction*distance+Vector3.new(0,20,0),Vector3.new(0,-40,0),params)
                if hit and hit.Material==Enum.Material.Water then target=hit.Position break end
            end
            if target then break end
        end
        if not target then error("No water around lake center for casting") end
        API.Water=target
        API.CastWater=target
        if API.SkyFishing then
            API.Spot=center+Vector3.new(0,math.clamp(Config.SkyFishingHeight,15,65),0)
            API.Water=center+Vector3.new(4,2,0)
            API.CastWater=center+Vector3.new(4,0,0)
        end
    else
        API.Spot=shore
        API.Water=castWater
        API.CastWater=castWater
        API.CenterWater=nil
    end
    API.ZoneSkill, API.ZoneName = chosen.Skill, chosen.Name
    updateProgress()
end
lakeTravel=function(token,destination)
    local _,hum,root=character()
    if not hum or not root then return false end
    local entering=API.CenterFishing and destination==API.Spot
    local changingLake=API.AtLakeCenter and entering and API.ActiveLakeSpot~=API.Spot
    local leaving=API.AtLakeCenter and (not entering or changingLake)
    if not entering and not leaving then return false end
    -- A failed swim retry can start with the character still on a parked car.
    -- Move to a verified dry point outside its bounds before entering the water.
    if entering then
        for _,model in ipairs(workspace.Vehicles:GetChildren()) do
            if model:GetAttribute("OwnerUserId")==player.UserId and validWorldPosition(model:GetPivot().Position) then
                local box,size=model:GetBoundingBox()
                local localPoint=box:PointToObjectSpace(root.Position)
                if math.abs(localPoint.X)<size.X/2+1.5 and math.abs(localPoint.Z)<size.Z/2+1.5 and math.abs(localPoint.Y)<size.Y/2+5 then
                    if hum.SeatPart then pcall(netGet,"exit_seat") hum.Sit=false task.wait(0.3) end
                    local ground=RaycastParams.new()
                    ground.FilterType=Enum.RaycastFilterType.Include
                    ground.FilterDescendantsInstances={workspace.Map,workspace.Terrain}
                    ground.RespectCanCollide=true
                    local space=OverlapParams.new()
                    space.FilterDescendantsInstances={player.Character}
                    space.RespectCanCollide=true
                    local best,bestScore
                    for _,side in ipairs({box.RightVector,-box.RightVector,box.LookVector,-box.LookVector}) do
                        local distance=(math.abs(side:Dot(box.RightVector))>0.5 and size.X or size.Z)/2+4
                        local point=box.Position+side*distance
                        local floor=workspace:Raycast(Vector3.new(point.X,API.Shore.Y+4,point.Z),Vector3.new(0,-20,0),ground)
                        if floor and floor.Material~=Enum.Material.Water and floor.Normal.Y>0.7 then
                            local standing=floor.Position+Vector3.new(0,hum.HipHeight+root.Size.Y/2+0.1,0)
                            if #workspace:GetPartBoundsInBox(CFrame.new(standing),Vector3.new(2.2,4.8,2.2),space)==0 then
                                local score=(standing-API.CenterWater).Magnitude
                                if not bestScore or score<bestScore then best,bestScore=standing,score end
                            end
                        end
                    end
                    if not best then return true,false,"No clear swim entry beside parked vehicle" end
                    hum:Move(Vector3.zero)
                    root.CFrame=CFrame.new(best)*root.CFrame.Rotation
                    root.AssemblyLinearVelocity=Vector3.zero
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                    logEvent("MOVE","Cleared parked vehicle before swimming")
                    task.wait(0.3)
                end
            end
        end
    end
    local function overWater(position)
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances={workspace.Terrain,workspace.Map}
        params.RespectCanCollide=true
        params.IgnoreWater=false
        local hit=workspace:Raycast(position+Vector3.new(0,30,0),Vector3.new(0,-80,0),params)
        return hit and hit.Material==Enum.Material.Water
    end
    if entering and not leaving and not overWater(root.Position) and (root.Position-API.Shore).Magnitude>8 then
        local route=(root.Position-API.Shore).Magnitude<=30 and walkingRoute or walkToSpot
        local ok,why=route(token,API.Shore,"Travelling to lake shore")
        if not ok then return true,false,why end
    end
    local target=leaving and (API.LakeExitShore or API.Shore) or API.CenterWater
    clearLakeSupport()
    if hum.SeatPart then pcall(netGet,"exit_seat") hum.Sit=false task.wait(0.3) end
    local deadline=os.clock()+math.max(30,(root.Position-target).Magnitude/5+15)
    local previous,lastProgress=root.Position,os.clock()
    API.Transport="Swimming"
    status(not leaving and "Swimming to lake center" or "Returning from lake center to shore")
    updateSwimmingSprint()
    while alive(token) and hum.Health>0 do
        local delta=Vector3.new(target.X-root.Position.X,0,target.Z-root.Position.Z)
        if delta.Magnitude<3 then break end
        updateSwimmingSprint()
        hum:MoveTo(target)
        if leaving and delta.Magnitude<10 and target.Y-root.Position.Y>2 then hum.Jump=true end
        if (root.Position-previous).Magnitude>2 then previous,lastProgress=root.Position,os.clock() end
        if os.clock()>deadline or os.clock()-lastProgress>8 then
            Sprint.sprinting.set(false)
            hum:Move(Vector3.zero)
            return true,false,"Lake swimming route blocked"
        end
        task.wait(0.1)
    end
    Sprint.sprinting.set(false)
    if not alive(token) or hum.Health<=0 then return true,false,"Lake movement cancelled" end
    hum:Move(Vector3.zero)
    if entering and not leaving then
        lakeSupport=Instance.new("Part")
        lakeSupport.Name="AutoFishingLakeSupport"
        lakeSupport.Size=Vector3.new(7,0.5,7)
        lakeSupport.Anchored=true
        lakeSupport.Transparency=1
        lakeSupport.CanTouch=false
        lakeSupport.CanQuery=false
        lakeSupport.Position=API.CenterWater+Vector3.new(0,1,0)
        lakeSupport.Parent=workspace
        root.CFrame=CFrame.new(API.Spot)*root.CFrame.Rotation
        root.AssemblyLinearVelocity=Vector3.zero
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        API.AtLakeCenter=true
        API.ActiveLakeSpot=API.Spot
        API.LakeExitShore=API.Shore
        logEvent("MOVE","Reached lake center: "..tostring(API.Spot))
        task.wait(0.3)
        return true,alive(token)
    end
    if changingLake then
        local ok,why=walkToSpot(token,destination,"Travelling to newly unlocked lake center")
        return true,ok,why
    end
    return false
end
do
    local activeSky
    local function skyRelease(state)
        if state.Hold then state.Hold:Disconnect() state.Hold=nil end
        if state.Platform then state.Platform:Destroy() state.Platform=nil end
        for part,collide in pairs(state.Collisions) do
            if part.Parent and (not part:IsDescendantOf(state.Car) or validWorldPosition(state.Car:GetPivot().Position)) then part.CanCollide=collide end
        end
        API.AtSkyFishing=false
        API.AtLakeCenter=false
        if activeSky==state then activeSky=nil end
    end
    local function skyStack(state,frame)
        assert(state.Car.Parent and validWorldPosition(state.Car:GetPivot().Position),"Sky car left valid world")
        assert(player.Character==state.Character and state.Humanoid.Health>0 and not API.ProtectionActive,"Sky movement cancelled")
        assert(validWorldPosition(frame.Position),"Invalid sky target")
        for part in pairs(state.Collisions) do
            if part.Parent then
                part.CanCollide=false
                part.AssemblyLinearVelocity=Vector3.zero
                part.AssemblyAngularVelocity=Vector3.zero
            end
        end
        state.Car:PivotTo(frame)
        local standing=frame:PointToWorldSpace(state.Roof)
        state.Platform.Position=standing-Vector3.new(0,state.Feet+0.2,0)
        state.Root.CFrame=CFrame.new(standing)*state.Rotation
        state.Root.AssemblyLinearVelocity=Vector3.zero
        API.VehicleLocation={Guid=state.Guid,Position=tostring(frame.Position),Sky=true}
    end
    local function skySlide(state,target,checkRunning)
        local from=state.Car:GetPivot()
        local duration=math.max(0.4,(from.Position-target.Position).Magnitude/math.clamp(Config.SkyTravelSpeed,10,50))
        local begun=os.clock()
        repeat
            if checkRunning and not alive(state.Token) then return false end
            local alpha=math.clamp((os.clock()-begun)/duration,0,1)
            skyStack(state,from:Lerp(target,alpha))
            if alpha>=1 then return true end
            RunService.Heartbeat:Wait()
        until false
    end
    local function skyLand(state)
        if state.Hold then state.Hold:Disconnect() state.Hold=nil end
        API.SkyState="Descending to shore"
        status("Sky Fishing - descending gradually to shore")
        pcall(function()player:RequestStreamAroundAsync(state.Shore,2)end)
        local ray=RaycastParams.new()
        ray.FilterType=Enum.RaycastFilterType.Include
        ray.FilterDescendantsInstances={workspace.Map,workspace.Terrain}
        ray.RespectCanCollide=true
        local overlap=OverlapParams.new()
        overlap.FilterDescendantsInstances={state.Character,state.Car,state.Platform}
        overlap.RespectCanCollide=true
        local landing
        for _,distance in ipairs({15,30,45}) do
            for i=0,7 do
                local q=state.Shore+Vector3.new(math.cos(i*math.pi/4)*distance,0,math.sin(i*math.pi/4)*distance)
                local hit=workspace:Raycast(q+Vector3.new(0,5,0),Vector3.new(0,-20,0),ray)
                if hit and hit.Material~=Enum.Material.Water and hit.Normal.Y>0.7 then
                    local box=CFrame.new(hit.Position+Vector3.new(0,state.Size.Y/2+0.2,0))
                    if #workspace:GetPartBoundsInBox(box,state.Size+Vector3.new(1,0,1),overlap)==0 then
                        landing=CFrame.new(q.X,hit.Position.Y+state.Bottom,q.Z)*state.CarRotation
                        break
                    end
                end
            end
            if landing then break end
        end
        assert(landing,"No clear place to land sky vehicle")
        local currentStanding=state.Car:GetPivot():PointToWorldSpace(state.Roof)
        local underY=state.SurfaceY-4
        local descentRoot=Vector3.new(currentStanding.X,underY,currentStanding.Z)
        local descent=CFrame.new(descentRoot-state.CarRotation:VectorToWorldSpace(state.Roof))*state.CarRotation
        assert(skySlide(state,descent,false),"Sky descent cancelled")
        local landedStanding=landing:PointToWorldSpace(state.Roof)
        local crossingRoot=Vector3.new(landedStanding.X,underY,landedStanding.Z)
        local crossing=CFrame.new(crossingRoot-state.CarRotation:VectorToWorldSpace(state.Roof))*state.CarRotation
        assert(skySlide(state,crossing,false),"Sky shore approach cancelled")
        assert(skySlide(state,landing,false),"Sky landing cancelled")
        local boxCenter=landing:PointToWorldSpace(state.BoxCenter)
        local standing
        for _,side in ipairs({landing.RightVector,-landing.RightVector,landing.LookVector,-landing.LookVector}) do
            local offset=(math.abs(side:Dot(landing.RightVector))>0.5 and state.Size.X or state.Size.Z)/2+3
            local point=boxCenter+side*offset
            local hit=workspace:Raycast(Vector3.new(point.X,state.Shore.Y+5,point.Z),Vector3.new(0,-20,0),ray)
            if hit and hit.Material~=Enum.Material.Water and hit.Normal.Y>0.7 then
                local target=hit.Position+Vector3.new(0,state.Feet,0)
                if #workspace:GetPartBoundsInBox(CFrame.new(target),Vector3.new(2.2,4.8,2.2),overlap)==0 then standing=target break end
            end
        end
        assert(standing,"No clear dismount position after sky landing")
        local from=state.Root.Position
        local begun=os.clock()
        repeat
            assert(player.Character==state.Character and state.Humanoid.Health>0,"Character changed during landing")
            local alpha=math.clamp((os.clock()-begun)/0.5,0,1)
            state.Root.CFrame=CFrame.new(from:Lerp(standing,alpha))*state.Rotation
            state.Root.AssemblyLinearVelocity=Vector3.zero
            if alpha>=1 then break end
            RunService.Heartbeat:Wait()
        until false
        skyRelease(state)
        API.SkyState="Idle"
        logEvent("MOVE","Sky Fishing landed beside car")
    end
    skyStop=function()
        local state=activeSky
        if not state or state.Landing then return end
        state.Landing=true
        env.BlockSpinSkyLanding=true
        task.spawn(function()
            local ok,err=pcall(skyLand,state)
            if not ok then skyRelease(state) API.LastWarning="Sky landing: "..tostring(err) end
            env.BlockSpinSkyLanding=nil
        end)
    end
    skyTravel=function(token,destination)
        local entering=API.SkyFishing and destination==API.Spot
        if activeSky and (not entering or activeSky.Spot~=API.Spot) then
            local state=activeSky
            state.Landing=true
            env.BlockSpinSkyLanding=true
            local ok,err=pcall(skyLand,state)
            env.BlockSpinSkyLanding=nil
            if not ok then skyRelease(state) return true,false,tostring(err) end
        end
        if not entering then return false end
        if activeSky then return true,true end
        local c,h,root=character()
        if not h or not root or not validWorldPosition(root.Position) then return true,false,"Character unavailable for sky fishing" end
        local owned,kind=ownedTravelVehicle()
        if kind~="car" then return true,false,"Sky Fishing requires an owned car" end
        local function findCar()
            for _,v in ipairs(workspace.Vehicles:GetChildren()) do
                if v:GetAttribute("OwnerUserId")==player.UserId and v:GetAttribute("ItemGUID")==owned.guid and validWorldPosition(v:GetPivot().Position) then return v end
            end
        end
        local car=findCar()
        local lakeDistance=Vector3.new(root.Position.X-API.CenterWater.X,0,root.Position.Z-API.CenterWater.Z).Magnitude
        if lakeDistance>80 or not car or (car:GetPivot().Position-root.Position).Magnitude>Config.CarNearbyDistance then
            API.SkyState="Approaching shore by vehicle"
            logEvent("MOVE","Driving to lake before starting sky ascent")
            tryOwnedTransport(token,API.Shore)
            if not alive(token) then return true,false,"Sky approach cancelled" end
            if API.TransportTripResult~="Arrived" and (root.Position-API.Shore).Magnitude>Config.CarFinalWalkDistance then
                return true,false,API.LastTransportError or "Waiting for vehicle to reach lake shore"
            end
            owned,kind=ownedTravelVehicle()
            car=findCar()
        end
        if not car or (car:GetPivot().Position-root.Position).Magnitude>Config.CarNearbyDistance then return true,false,API.LastTransportError or "Waiting for nearby car for sky fishing" end
        if h.SeatPart then pcall(netGet,"exit_seat") h.Sit=false task.wait(0.3) end
        local seat=car:FindFirstChild("DriverSeat",true)
        if not seat or seat.Occupant then return true,false,"Sky car is occupied" end
        local frame=car:GetPivot()
        local box,size=car:GetBoundingBox()
        local template=Items.get_item_instance(owned.name)
        if template then
            local templateBox,templateSize=template:GetBoundingBox()
            local relative=template:GetPivot():ToObjectSpace(templateBox)
            box=frame*relative
            size=templateSize
        end
        local feet=h.HipHeight+root.Size.Y/2+0.1
        local boxLocal=frame:PointToObjectSpace(box.Position)
        local roof=Vector3.new(boxLocal.X,boxLocal.Y+size.Y/2+feet+0.1,boxLocal.Z)
        local platform=Instance.new("Part")
        platform.Name="AutoFishingSkyCarPlatform"
        platform.Size=Vector3.new(6,0.4,6)
        platform.Anchored=true
        platform.Transparency=1
        platform.CanTouch=false
        platform.CanQuery=false
        platform.Position=frame:PointToWorldSpace(roof)-Vector3.new(0,feet+0.2,0)
        platform.Parent=workspace
        local state={Car=car,Guid=owned.guid,Character=c,Humanoid=h,Root=root,Feet=feet,Roof=roof,Platform=platform,
            Size=size,BoxCenter=boxLocal,Bottom=frame.Position.Y-(box.Position.Y-size.Y/2)+0.1,
            Rotation=root.CFrame.Rotation,CarRotation=frame.Rotation,Shore=API.Shore,SurfaceY=API.CenterWater.Y,Spot=API.Spot,Token=token,Collisions={}}
        for _,model in ipairs({car,c}) do for _,part in model:QueryDescendants("BasePart") do state.Collisions[part]=part.CanCollide;part.CanCollide=false end end
        activeSky=state
        API.SkyState="Climbing onto car"
        Sprint.sprinting.set(false)
        h:Move(Vector3.zero)
        local from=root.Position
        local top=frame:PointToWorldSpace(roof)
        local begun=os.clock()
        local duration=math.max(0.5,(from-top).Magnitude/15)
        repeat
            if not alive(token) then return true,false,"Sky climb cancelled" end
            local alpha=math.clamp((os.clock()-begun)/duration,0,1)
            car:PivotTo(frame)
            root.CFrame=CFrame.new(from:Lerp(top,alpha))*state.Rotation
            root.AssemblyLinearVelocity=Vector3.zero
            if alpha>=1 then break end
            RunService.Heartbeat:Wait()
        until false
        if Vector3.new(root.Position.X-API.CenterWater.X,0,root.Position.Z-API.CenterWater.Z).Magnitude>3 then
            API.SkyState="Approaching fishing point below water"
            status("Moving below water to sky fishing point")
            local underY=API.CenterWater.Y-4
            local startStanding=state.Car:GetPivot():PointToWorldSpace(roof)
            local underStart=Vector3.new(startStanding.X,underY,startStanding.Z)
            local dive=CFrame.new(underStart-frame.Rotation:VectorToWorldSpace(roof))*frame.Rotation
            if not skySlide(state,dive,true) then return true,false,"Lake approach cancelled" end
            local underCenter=Vector3.new(API.CenterWater.X,underY,API.CenterWater.Z)
            local crossing=CFrame.new(underCenter-frame.Rotation:VectorToWorldSpace(roof))*frame.Rotation
            if not skySlide(state,crossing,true) then return true,false,"Lake approach cancelled" end
        end
        API.SkyState="Ascending"
        status("Sky Fishing - ascending gradually")
        local target=CFrame.new(API.Spot-frame.Rotation:VectorToWorldSpace(roof))*frame.Rotation
        if not skySlide(state,target,true) then return true,false,"Sky ascent cancelled" end
        API.SkyState="Fishing"
        API.AtSkyFishing=true
        API.AtLakeCenter=true
        state.Hold=RunService.Heartbeat:Connect(function()
            if activeSky~=state or state.Landing then return end
            local ok,err=pcall(skyStack,state,target)
            if not ok and API.Running then API.Retry("Sky hold failed: "..tostring(err)) end
        end)
        logEvent("MOVE","Sky Fishing ready at "..tostring(API.Spot))
        return true,true
    end
end
local function ownedRod(name)
    local found = false
    Items.iterate_through_items_of_type(Data, "rod", function(item)
        if item.location == "hand" and (item.name == name or item.class and item.class.name == name) then found = true end
    end)
    return found
end
local function baitAmount(ammo)
    local amount = 0
    Items.iterate_through_items_of_type(Data, "ammo", function(item)
        if item.location == "hand" and (item.class and item.class.name or item.name) == ammo then amount += item.amount or 0 end
    end)
    return amount
end
local function crossHardwareDoor(token,entering)
    local _,hum,root=character()
    if not hum or not root then return false end
    local target=Vector3.new(entering and -110 or -89,255.5,133.2)
    local wasTravelling=API.Travelling
    API.Travelling=true
    API.Transport="Running"
    status(entering and "Entering hardware through public door" or "Exiting hardware through public door")
    local deadline=os.clock()+8
    local reached=false
    repeat
        if not alive(token) or hum.Health<=0 then break end
        updateTravelSprint()
        hum:MoveTo(target)
        local delta=root.Position-target
        if Vector3.new(delta.X,0,delta.Z).Magnitude<2.5 and math.abs(delta.Y)<4 then reached=true break end
        task.wait(Config.ObstaclePollInterval)
    until os.clock()>deadline
    API.Travelling=wasTravelling
    Sprint.sprinting.set(false)
    if not reached and alive(token) then error("Hardware door crossing blocked; retrying through entrance") end
    return reached
end
leaveHardware=function(token)
    if not walkingRoute(token,Vector3.new(-110,255.5,133.2),"Following hardware exit aisle") then return false end
    return crossHardwareDoor(token,false)
end
local function purchase(token, name, quantity, totalCost)
    if totalCost <= 0 or cash() + bank() < totalCost then return false end
    if not alive(token) then return false end
    local shop = workspace:FindFirstChild("ShopZone_Hardware")
    if not shop then error("Hardware shop not found") end
    if cash() < totalCost then
        if not Config.AllowPurchaseWithdrawals then return false end
        if not transfer(token, "bank", "hand", totalCost - cash()) then return false end
    end
    -- Enter through the hardware store's public double doors; do not target its roof.
    local _,_,shopRoot=character()
    local inShop=shopRoot and shopRoot.Position.X>-170 and shopRoot.Position.X<-98 and shopRoot.Position.Z>96 and shopRoot.Position.Z<174 and shopRoot.Position.Y>248 and shopRoot.Position.Y<263
    if not inShop and not moveTo(token, Vector3.new(-89,255.5,133.2), "Running to hardware entrance") then return false end
    if not inShop and not crossHardwareDoor(token,true) then return false end
    if not moveTo(token, shop.Position, "Buying "..quantity.." x "..name) then return false end
    if not alive(token) then return false end
    local accepted, reason = netGet("purchase_consumable", shop, name, quantity)
    API.LastPurchase={Name=name,Quantity=quantity,Cost=totalCost,Accepted=accepted,Reason=reason}
    logEvent("BUY",string.format("%d x %s; $%d; accepted=%s",quantity,name,totalCost,tostring(accepted)))
    if not accepted then
        deposit(token)
        error("Purchase rejected for " .. name .. ": " .. tostring(reason))
    end
    task.wait(0.4)
    if not alive(token) then return false end
    if not moveTo(token, Vector3.new(-110,255.5,133.2), "Leaving hardware counter") then return false end
    if not crossHardwareDoor(token,false) then return false end
    return true
end
local function hasUsableRod()
    local found=false
    Items.iterate_through_items_of_type(Data,"rod",function(item)
        if item.location=="hand" and not item.destroyed and (not item.durability or item.durability>0) then found=true end
    end)
    return found
end
local function starterChoices()
    local rod,bait
    for _,unlock in ipairs(Unlocks) do
        local name=unlock.reward_info and unlock.reward_info.tool_name
        if name and Skills.has_skill(Data,"fishing",unlock.name) then
            local model=Items.get_item_instance(name)
            local kind=model and model:GetAttribute("FishingItem")
            local cost=model and Items.get_item_rarity_price(name)
            if type(cost)=="number" and cost>0 then
                if kind=="rod" and (not rod or (Config.AutoUpgradeRods and unlock.level>rod.Level) or (not Config.AutoUpgradeRods and cost<rod.Cost)) then
                    rod={Name=name,Cost=cost,Level=unlock.level}
                end
                if kind=="bait" and name~="Squidtec" and (not bait or unlock.level>bait.Level) then
                    bait={Name=name,Cost=cost,Level=unlock.level,Ammo=Items.get_item_ammo_type(name)}
                end
            end
        end
    end
    return rod,bait
end
local function starterFunds()
    return cash()+(Config.AllowPurchaseWithdrawals and bank() or 0)
end
local function jobBox()
    local currentCharacter=player.Character
    local box=currentCharacter and currentCharacter:FindFirstChild("BoxTool")
    if not box then
        box=player.Backpack:FindFirstChild("BoxTool")
        local _,hum=character()
        if box and hum then hum:EquipTool(box) end
    end
    return box
end
local function stockerStep(token,position,caption)
    local _,hum,root=character()
    if not hum or not root then error("Character unavailable during Stocker travel") end
    local function inHardware(point)
        return point.X>-170 and point.X<-98 and point.Z>96 and point.Z<174
    end
    if leaveHardware and inHardware(root.Position) and not inHardware(position) then
        if not leaveHardware(token) then error("Hardware exit blocked while travelling to Stocker") end
    end
    status(caption)
    API.Travelling=true
    API.Transport="Running"
    API.StockerWaypoint=tostring(position)
    logEvent("STOCKER",caption.." -> "..tostring(position),"stocker-waypoint",0.2)
    local insideShop=root.Position.X>=85 and root.Position.X<=173 and root.Position.Z>=158 and root.Position.Z<=220
    if not insideShop and (root.Position-position).Magnitude>60 then
        return moveTo(token,position,caption)
    end
    local lastPosition,lastProgress=root.Position,os.clock()
    local deadline=os.clock()+math.max(10,(root.Position-position).Magnitude/7+4)
    hum:MoveTo(position)
    while alive(token) do
        local delta=Vector3.new(root.Position.X-position.X,0,root.Position.Z-position.Z).Magnitude
        if delta<Config.StockerArrivalDistance then break end
        if hum.Health<=0 then error("Character died during Stocker travel") end
        if hum.SeatPart then hum.Sit=false hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
        if (root.Position-lastPosition).Magnitude>0.5 then lastPosition,lastProgress=root.Position,os.clock() end
        if os.clock()-lastProgress>Config.StockerBlockedTime or os.clock()>deadline then
            logEvent("STOCKER","Corridor obstructed; recalculating on foot","stocker-blocked",1)
            -- Local shop recovery must not spawn a vehicle indoors.
            local reached,reason=walkingRoute(token,position,caption)
            if not reached and alive(token) then error(reason or "Stocker corridor blocked") end
            return reached and alive(token)
        end
        task.wait(0.05)
    end
    -- Keep movement continuous between the adjacent aisle waypoints.
    return alive(token)
end
local function assignedStockShelf()
    local assigned=API.StockerShelf
    if assigned and assigned.Parent and assigned:IsA("BasePart") then
        return assigned
    end
    -- Recover the native direct_to_shelf target when resuming with a held box.
    if jobBox() then
        for _,value in pairs(debug.getupvalues(ShelfStocking.initiate)) do
            if typeof(value)=="Instance" and value:IsA("BasePart") and value.Parent and value.Parent.Name=="Shelves" then
                API.StockerShelf=value
                return value
            end
        end
    end
    for shelf,object in pairs(ShelfStocking.shelf_class.objects) do
        if shelf:IsDescendantOf(workspace) and object.states.player_assigned.get()==player then return shelf end
    end
end
local function closeJobDialog()
    local gui=player:FindFirstChildOfClass("PlayerGui")
    if gui then pressGameButton(gui:FindFirstChild("CancelJob",true)) end
end
local function earnStarterFunds(token,target)
    API.Phase="Stocker"
    API.EarningForRod=true
    API.StarterTarget=target
    player:RequestStreamAroundAsync(Vector3.new(149,255,203),3)
    local beacon
    for instance,object in pairs(JobApplication.class.objects) do
        if instance:IsDescendantOf(workspace) and object.states.JobIndex.get()=="shelf_stocker" then beacon=instance break end
    end
    if not beacon then error("Shelf Stocker job board not found") end
    local normalBox=workspace.Map.Tiles.GasStationTile.Quick11.Interior.ShelfStockingJob:FindFirstChild("NormalBox")
    local prompt=normalBox and normalBox:FindFirstChildWhichIsA("ProximityPrompt",true)
    if not normalBox or not prompt or type(fireproximityprompt)~="function" then error("Normal stock box/prompt unavailable") end
    local progress=loadModule("Game.UI.ProgressBar")
    local _,_,entryRoot=character()
    local insideShop=entryRoot and entryRoot.Position.X>=85 and entryRoot.Position.X<=173 and entryRoot.Position.Z>=158 and entryRoot.Position.Z<=220
    if not insideShop then
        if not stockerStep(token,Vector3.new(129,255.4,151),"Going to Quick11 entrance") then return false end
        if not stockerStep(token,Vector3.new(129,255.4,170),"Entering Quick11 through public door") then return false end
    end
    if player:GetAttribute("Job")~="shelf_stocker" then
        local _,_,root=character()
        if root.Position.Z<158 or root.Position.X<90 or root.Position.X>173 then
            if not stockerStep(token,Vector3.new(129,255.4,151),"Going to Quick11 for starter funds") then return false end
            if not stockerStep(token,Vector3.new(129,255.4,170),"Entering Quick11") then return false end
        end
        if root.Position.Z<196 then
            if not stockerStep(token,Vector3.new(130,255.4,189),"Following the shop aisle") then return false end
            if not stockerStep(token,Vector3.new(130,255.4,203),"Going to Stocker job board") then return false end
            if not stockerStep(token,Vector3.new(145,255.4,203),"Entering stock room") then return false end
        end
        if not stockerStep(token,beacon.TouchPart.Position,"Applying for Shelf Stocker") then return false end
        netSend("apply_for_job",beacon)
        if not waitFor(token,function()return player:GetAttribute("Job")=="shelf_stocker" end,5) then error("Stocker job application not confirmed") end
        closeJobDialog()
    end
    while alive(token) and starterFunds()<target do
        local _,hum,root=character()
        local workCharacter=player.Character
        local before=cash()+bank()
        if not hum or hum.Health<=0 then error("Character unavailable during starter job") end
        if player:GetAttribute("Job")~="shelf_stocker" then error("Shelf Stocker job was lost; reapplying automatically") end
        if not jobBox() then
            API.StockerShelf=nil
            if root.Position.X<137 then
                if not stockerStep(token,Vector3.new(130,255.4,root.Position.Z),"Leaving shelf row") then return false end
                if not stockerStep(token,Vector3.new(130,255.4,203),"Leaving shelf aisle") then return false end
            end
            if not stockerStep(token,Vector3.new(145,255.4,203),"Going to stock boxes") then return false end
            -- The prompt reaches farther than the physical crate; stop in front
            -- of it instead of trying to walk through its collidable mesh.
            local pickupAt=normalBox.Position+Vector3.new(0,0,-5)
            if (root.Position-normalBox.Position).Magnitude>math.max(3,prompt.MaxActivationDistance-1) then
                if not stockerStep(token,pickupAt,"Approaching stock box pickup") then return false end
            end
            API.Travelling=false
            Sprint.sprinting.set(false)
            hum:MoveTo(root.Position)
            fireproximityprompt(prompt)
            if not waitFor(token,function()return jobBox()~=nil end,5) then error("Stock box pickup not confirmed") end
        end
        if not waitFor(token,function()return assignedStockShelf()~=nil end,5) then error("No shelf assigned by server") end
        local shelf=assignedStockShelf()
        -- Shelf trigger centres are already in the walking aisles. Adding half
        -- the trigger depth put the old approach inside the physical shelving.
        local aisleZ=shelf.Position.Z
        if root.Position.X>137 then
            if not stockerStep(token,Vector3.new(145,255.4,203),"Carrying stock to the shop") then return false end
            if not stockerStep(token,Vector3.new(130,255.4,203),"Entering shelf aisle") then return false end
        end
        local alreadyInRow=root.Position.X>98 and root.Position.X<127 and math.abs(root.Position.Z-aisleZ)<2.5
        if not alreadyInRow then
            if root.Position.X<127 then
                if not stockerStep(token,Vector3.new(130,255.4,root.Position.Z),"Leaving current row through clear aisle") then return false end
            end
            if not stockerStep(token,Vector3.new(130,255.4,aisleZ),"Finding assigned shelf row") then return false end
        end
        if not stockerStep(token,Vector3.new(shelf.Position.X,255.4,aisleZ),"Approaching assigned shelf") then return false end
        -- Touching the assigned shelf runs the native timed stocking interaction.
        status("Stocking shelf for fishing equipment")
        API.Travelling=false
        Sprint.sprinting.set(false)
        hum:MoveTo(Vector3.new(shelf.Position.X,root.Position.Y,shelf.Position.Z))
        local began=waitFor(token,function()return progress.bar_enabled.get() or cash()+bank()>before end,2)
        if not alive(token) then return false end
        if not began and jobBox() and (root.Position-shelf.Position).Magnitude<9 then
            local begin=filtergc("function",{Name="begin_stocking",Upvalues={shelf}},true)
            if begin then task.spawn(begin,root) end
        end
        hum:MoveTo(root.Position)
        local paid=waitFor(token,function()
            if player.Character~=workCharacter or hum.Health<=0 or hum:GetAttribute("IsDead")==true then error("Character died during stocking") end
            return not progress.bar_enabled.get() and cash()+bank()>before
        end,Config.StockerWorkTimeout)
        if not alive(token) then return false end
        if not paid then error("Stocking cycle did not produce a confirmed payment") end
        -- Some stock boxes can remain equipped; wait briefly for the server's
        -- next assignment without insisting that the tool must disappear.
        waitFor(token,function()return jobBox()==nil or assignedStockShelf()~=shelf end,0.35)
        if not alive(token) then return false end
        API.StockerCycles=(API.StockerCycles or 0)+1
        API.RetryCount=0
        API.StockerEarned=(API.StockerEarned or 0)+(cash()+bank()-before)
        if API.StartupKitPlan and not API.StartupKitReady then
            API.StartupKitPlan.MissingFunds=math.max(0,API.StartupKitPlan.RequiredFunds-starterFunds())
        end
        status(string.format("Stocker equipment funds $%d / $%d",starterFunds(),target))
        if Config.BankStockerPay and Config.AllowPurchaseWithdrawals and cash()>=Config.DepositThreshold then
            if not transfer(token,"hand","bank",cash()) then return false end
        elseif Config.AllowPurchaseWithdrawals and cash()>=Config.DepositThreshold and starterFunds()<target then
            if not deposit(token) then return false end
        end
    end
    if not alive(token) then return false end
    netSend("leave_job")
    if not waitFor(token,function()return player:GetAttribute("Job")~="shelf_stocker" end,5) then error("Leaving Stocker job was not confirmed") end
    closeJobDialog()
    API.EarningForRod=false
    local _,_,exitRoot=character()
    local insideShop=exitRoot and exitRoot.Position.X>=85 and exitRoot.Position.X<=173 and exitRoot.Position.Z>=158 and exitRoot.Position.Z<=220
    if insideShop and exitRoot.Position.X>137 then
        if not stockerStep(token,Vector3.new(145,255.4,203),"Leaving stock room") then return false end
        if not stockerStep(token,Vector3.new(130,255.4,203),"Returning to shop aisle") then return false end
    end
    if insideShop then
        if exitRoot.Position.X<100 then
            if not stockerStep(token,Vector3.new(exitRoot.Position.X,255.4,163),"Leaving ATM corner") then return false end
            if not stockerStep(token,Vector3.new(129,255.4,163),"Following front shop corridor") then return false end
        else
            if not stockerStep(token,Vector3.new(130,255.4,exitRoot.Position.Z),"Leaving Quick11 aisle") then return false end
            if not stockerStep(token,Vector3.new(129,255.4,163),"Going to Quick11 exit") then return false end
        end
        if not stockerStep(token,Vector3.new(129,255.4,151),"Leaving Quick11 to buy fishing gear") then return false end
    end
    API.StockerShelf=nil
    API.Travelling=false
    Sprint.sprinting.set(false)
    API.Phase="Preparing fishing equipment"
    return true
end
local function ensureStarterRod(token)
    if hasUsableRod() then API.EarningForRod=false API.Phase="Fishing" return true end
    local rod,bait=starterChoices()
    if not rod or not bait then error("Starter fishing rod/bait unlocks are unavailable") end
    local neededBait=math.max(0,math.clamp(Config.StarterBaitAmount,1,50)-baitAmount(bait.Ammo))
    local target=rod.Cost+neededBait*bait.Cost
    if starterFunds()<target then
        if not Config.BootstrapWithStocker then error("Insufficient starter funds; enable BootstrapWithStocker") end
        if not earnStarterFunds(token,target) then return false end
    end
    if not alive(token) then return false end
    if not purchase(token,rod.Name,1,rod.Cost) then return false end
    if not waitFor(token,hasUsableRod,5) then error("Starter rod purchase was not confirmed") end
    API.StarterRodPurchased=rod.Name
    API.Phase="Fishing"
    return true
end
local function ensureStartupKit(token)
    if not ensureCarCrate(token) then return false end
    if not Config.PrepareFullKitOnStart then return ensureStarterRod(token) end
    if API.StartupKitReady and hasUsableRod() and (not Config.AutoBuyBike or ownedTravelVehicle()) then return true end
    if inventoryFull() and fishCount()>0 then if not sellFish(token) then return false end end
    local rod,bait=starterChoices()
    if not rod or not bait then error("Starter rod or bait definition is unavailable") end
    if Config.ReuseExistingStartupKit and hasUsableRod() and (not Config.AutoBuyBike or ownedTravelVehicle()) and baitAmount(bait.Ammo)>0 then
        API.StartupKitReady=true
        API.DesiredRod,API.DesiredBait=rod.Name,bait.Name
        API.Phase="Fishing"
        logEvent("STARTUP","Reusing owned fishing kit; bait already available: "..bait.Name)
        return true
    end
    local targetBait=math.clamp(Config.StarterBaitAmount,1,50)
    local needRod=not hasUsableRod()
    local needBike=Config.AutoBuyBike and not ownedTravelVehicle()
    local bikeCost=0
    if needBike then
        local _,option,price=bikeOffer(token)
        if not alive(token) then return false end
        if not option then error("Bike shop case not available; will retry startup preparation") end
        bikeCost=price
    end
    local baitToBuy=math.max(0,targetBait-baitAmount(bait.Ammo))
    API.DesiredRod,API.DesiredBait=rod.Name,bait.Name
    logEvent("BUY","Startup gear target: "..rod.Name.."; "..targetBait.." x "..bait.Name)
    local reserve=needBike and Config.BikePurchaseReserve or 0
    local target=(needRod and rod.Cost or 0)+baitToBuy*bait.Cost+bikeCost+reserve
    API.StartupKitPlan={Rod=rod.Name,NeedRod=needRod,Bait=bait.Name,BaitTarget=targetBait,BaitToBuy=baitToBuy,
        NeedBike=needBike,BikeCost=bikeCost,RequiredFunds=target,MissingFunds=math.max(0,target-starterFunds())}
    API.Phase="Startup equipment"
    logEvent("STARTUP",string.format("Equipment budget $%d; available $%d; missing $%d",target,starterFunds(),math.max(0,target-starterFunds())))
    if starterFunds()<target then
        if not Config.BootstrapWithStocker then error("Enable BootstrapWithStocker to earn startup equipment funds") end
        if not earnStarterFunds(token,target) then return false end
    end
    if not alive(token) then return false end
    -- Recheck car purchase after earning funds before buying a bike.
    if not ensureCarCrate(token) then return false end
    if needBike and not ownedTravelVehicle() then
        if not ensureBike(token) then return false end
        if not ownedTravelVehicle() then error("Bike not received: "..tostring(API.BikePurchaseStatus or API.LastWarning)) end
    end
    if not hasUsableRod() then
        if not purchase(token,rod.Name,1,rod.Cost) then error("Could not purchase startup fishing rod") end
        if not waitFor(token,hasUsableRod,5) then error("Startup rod was not confirmed in inventory") end
    end
    baitToBuy=math.max(0,targetBait-baitAmount(bait.Ammo))
    if baitToBuy>0 then
        if not purchase(token,bait.Name,baitToBuy,baitToBuy*bait.Cost) then error("Could not purchase startup bait") end
        if not waitFor(token,function()return baitAmount(bait.Ammo)>=targetBait end,5) then error("Startup bait quantity not confirmed") end
    end
    if not hasUsableRod() or (Config.AutoBuyBike and not ownedTravelVehicle()) or baitAmount(bait.Ammo)<targetBait then
        error("Startup equipment changed before confirmation; rechecking requirements")
    end
    API.StartupKitReady=true
    API.StartupKitPlan.MissingFunds=0
    API.RetryCount=0
    API.Phase="Fishing"
    logEvent("STARTUP","Equipment ready: bike, rod and "..targetBait.." bait")
    return true
end

local function prepareEquipment(token)
    if Config.EnableDeepSea and Config.AutoLicense and API.DeepSeaAvailable and API.Level>=Skills.get_level_for_skill("fishing","FishingLicense") and not Data.has_fishing_license then
        local licenseCost=2500000
        if cash()+bank()>=licenseCost+Items.get_item_rarity_price("Squidtec") then
            if not purchase(token,"FishingLicense",1,licenseCost) then return false end
            if not waitFor(token,function()return Data.has_fishing_license==true end) then error("Fishing license purchase not confirmed") end
            API.ZoneSkill=nil
            selectZone()
        end
    end
    local desiredRod, desiredBait
    local rodLevel,baitLevel=-1,-1
    for _, unlock in ipairs(Unlocks) do
        if Skills.has_skill(Data,"fishing",unlock.name) and unlock.reward_info and unlock.reward_info.tool_name then
            local name = unlock.reward_info.tool_name
            local model = Items.get_item_instance(name)
            if model and model:GetAttribute("FishingItem") == "rod" and unlock.level>rodLevel then desiredRod,rodLevel=name,unlock.level end
            -- Squidtec only works around Deep Sea Island, so keep mainland bait for mainland zones.
            if model and model:GetAttribute("FishingItem") == "bait" and name ~= "Squidtec" and unlock.level>baitLevel then desiredBait,baitLevel=name,unlock.level end
        end
    end
    if Config.AutoUpgradeRods and desiredRod and not ownedRod(desiredRod) then
        local cost = Items.get_item_rarity_price(desiredRod)
        if cash() + bank() >= cost and not inventoryFull() then
            if not purchase(token, desiredRod, 1, cost) then return false end
            if not waitFor(token, function() return ownedRod(desiredRod) end) then error("Purchased rod not received") end
        end
    end
    if not desiredBait then error("No unlocked mainland bait found") end
    local existingName, existingAmmo
    local existingLevel=-1
    for _,unlock in ipairs(Unlocks) do
        local name=unlock.reward_info and unlock.reward_info.tool_name
        if name and name~="Squidtec" and unlock.level<=API.Level then
            local model=Items.get_item_instance(name)
            if model and model:GetAttribute("FishingItem")=="bait" and unlock.level>existingLevel then
                local ammoType=Items.get_item_ammo_type(name)
                if baitAmount(ammoType)>0 then existingName,existingAmmo,existingLevel=name,ammoType,unlock.level end
            end
        end
    end
    if API.ZoneSkill=="DeepSeaIsland" then
        desiredBait="Squidtec"
        local squid=Items.get_item_ammo_type("Squidtec")
        existingName,existingAmmo=baitAmount(squid)>0 and "Squidtec" or nil,baitAmount(squid)>0 and squid or nil
    end
    API.DesiredRod,API.DesiredBait=desiredRod,desiredBait
    local desiredAmmo=Items.get_item_ammo_type(desiredBait)
    if existingAmmo==desiredAmmo then
        API.BaitName,API.BaitAmmo=existingName,existingAmmo
        return deposit(token)
    end
    local ammo = Items.get_item_ammo_type(desiredBait)
    if existingAmmo and existingAmmo~=ammo then
        logEvent("BUY","Bait upgrade: "..tostring(existingName).." -> "..desiredBait)
    end
    if baitAmount(ammo) <= Config.BaitLowWater and not inventoryFull() then
        local price = Items.get_item_rarity_price(desiredBait)
        local tripAmount=Config.BaitPerTrip
        local refillCost=price*math.max(1,tripAmount-baitAmount(ammo))
        if starterFunds()<refillCost and Config.BootstrapWithStocker then
            status("Earning bait funds without selling a partial fish inventory")
            if not earnStarterFunds(token,refillCost) then return false end
        end
        local quantity = math.min(tripAmount - baitAmount(ammo), math.floor(starterFunds() / price), 50)
        if quantity > 0 then
            local before = baitAmount(ammo)
            if not purchase(token, desiredBait, quantity, price * quantity) then return false end
            if not waitFor(token, function() return baitAmount(ammo) > before end) then error("Purchased bait not received") end
        end
    end
    if baitAmount(ammo) > 0 then
        API.BaitName, API.BaitAmmo = desiredBait, ammo
    else
        -- If the new tier is unaffordable, use the best compatible bait already owned.
        API.BaitName, API.BaitAmmo = nil, nil
        for _, unlock in ipairs(Unlocks) do
            local name = unlock.reward_info and unlock.reward_info.tool_name
            if name and name ~= "Squidtec" and unlock.level <= API.Level then
                local model = Items.get_item_instance(name)
                if model and model:GetAttribute("FishingItem") == "bait" then
                    local candidate = Items.get_item_ammo_type(name)
                    if baitAmount(candidate) > 0 then API.BaitName, API.BaitAmmo = name, candidate end
                end
            end
        end
    end
    if API.ZoneSkill=="DeepSeaIsland" and API.BaitAmmo~=Items.get_item_ammo_type("Squidtec") then
        rejectedZones.DeepSeaIsland=true
        API.ZoneSkill=nil
        API.LastWarning="Squidtec unavailable; returning to the highest mainland area"
        selectZone()
    end
    if not API.BaitAmmo then
        error("No bait or funds available; add funds then restart")
    end
    return deposit(token)
end

API.Snapshot = function()
    return {Level = API.Level, XP = API.FishingXP, Zone = API.ZoneName, Bait = API.BaitName,
        DesiredRod=API.DesiredRod,DesiredBait=API.DesiredBait,
        CarCrateStatus=API.CarCrateStatus,CarCratePrice=API.CarCratePrice,CarCratesPurchased=API.CarCratesPurchased or 0,
        Fish = fishCount(), Inventory = Items.get_inventory_count(Data).hand, Capacity = capacity,
        Cash = cash(), Bank = bank(), Sold = API.Sold, Deposited = API.Deposited, Withdrawn = API.Withdrawn,
        LastSaleReason=API.LastSaleReason,LastSellSkip=API.LastSellSkip,
        Running = API.Running, Status = API.Status, Error = API.LastError, Transport=API.Transport,
        Warning=API.LastWarning, License=Data.has_fishing_license==true, NextUnlock=API.NextUnlock,
        DeepSeaAvailable=API.DeepSeaAvailable,Spot=tostring(API.Spot),Water=tostring(API.Water),
        CenterFishing=API.CenterFishing,AtLakeCenter=API.AtLakeCenter,Shore=tostring(API.Shore),
        SkyFishing=API.SkyFishing,AtSkyFishing=API.AtSkyFishing or false,SkyState=API.SkyState or "Idle",
        ObstacleFlights=API.ObstacleFlights or 0,LastVaultDuration=API.LastVaultDuration,
        NoclipPasses=API.NoclipPasses or 0,NoclipActive=API.NoclipActive or false,
        MovementMode=API.MovementMode,MovementGoal=API.MovementGoal,
        MovementReplans=API.MovementReplans or 0,StuckRecoveries=API.StuckRecoveries or 0,
        LastObstacle=API.LastObstacle,LogCount=#logHistory,
        StartupClicks=startup.Clicks,StartupCompleted=startup.Completed,
        StartupKitReady=API.StartupKitReady or false,StartupKitPlan=API.StartupKitPlan,
        RetryCount=API.RetryCount or 0,LastRetryReason=API.LastRetryReason,
        RetryIn=API.NextRetryAt and math.max(0,math.ceil(API.NextRetryAt-os.clock())) or 0,
        ProtectionActive=API.ProtectionActive or false,ProtectionState=API.Protection.State,
        ProtectionFullyHidden=API.Protection.FullyHidden or false,ProtectionClearance=API.Protection.HideClearance,
        ServerHopState=API.Protection.HopState,ServerHopTarget=API.Protection.Target,
        ServerHopAttempts=API.Protection.Attempts,ServerHopError=API.Protection.LastError,
        DropsCollected=API.DropsCollected or 0,DeathRecoveries=API.DeathRecoveries or 0,
        DeathLootPending=API.DeathRecovery~=nil,BikesPurchased=API.BikesPurchased or 0,BikePurchaseStatus=API.BikePurchaseStatus,
        TransportTrips=API.TransportTrips or 0,TransportError=API.LastTransportError,
        SelectedVehicle=API.SelectedVehicle,TransportTripResult=API.TransportTripResult,
        BikeRoutesCompleted=API.BikeRoutesCompleted or 0,BikeDetours=API.BikeDetours or 0,BikeReplans=API.BikeReplans or 0,
        UndergroundActive=API.UndergroundActive or false,UndergroundPhase=API.UndergroundPhase or "Idle",
        UndergroundTrips=API.UndergroundTrips or 0,UndergroundExit=API.UndergroundExit,
        UndergroundCurrentSpeed=API.UndergroundActive and API.UndergroundCurrentSpeed or 0,
        BikeWaypoint=API.BikeWaypoint,BikeBlockedPart=API.BikeBlockedPart,BikeRoadIssue=API.BikeRoadIssue,
        ScooterRefreshes=API.ScooterRefreshes or 0,ScooterSpawnDistance=API.LastScooterSpawnDistance,
        VehicleReply=API.LastVehicleReply,ObstaclePollInterval=Config.ObstaclePollInterval,
        LastObstacleResponseTime=API.LastObstacleResponseTime,
        DismissedPrompts=API.DismissedPrompts,LastDismissedPrompt=API.LastDismissedPrompt,
        AutoPlayCompleted=API.AutoPlayCompleted or false,AutoPlayAttempts=API.AutoPlayAttempts or 0,
        AutoAvatarSkipAttempts=API.AutoAvatarSkipAttempts or 0,
        StockerCycles=API.StockerCycles or 0,StockerEarned=API.StockerEarned or 0,
        StockerWaypoint=API.StockerWaypoint,
        StarterTarget=API.StarterTarget,StarterRodPurchased=API.StarterRodPurchased,Phase=API.Phase,
        AutoRespawnAttempts=API.AutoRespawnAttempts or 0,AutoRespawns=API.AutoRespawns or 0}
end
API.SellNow=function() API.SellRequested=true end
dataHooks[#dataHooks + 1] = Data.hook("money", function() if not destroyed then updateProgress() end end)
dataHooks[#dataHooks + 1] = Data.hook("xp", function() if not destroyed then updateProgress() end end)
updateProgress()

connections[#connections + 1] = RS.Remotes.Send.OnClientEvent:Connect(function(event, id, a)
    if event=="direct_to_shelf" and typeof(id)=="Instance" then API.StockerShelf=id end
    if not API.Running or not ownedCast then return end
    if event == "minigame_open" then
        sessionId = id
        pendingLevel = nil
    elseif event == "minigame_level" and id == sessionId then
        pendingLevel = nil
    elseif event == "minigame_result" and id == sessionId then
        if a == true then
            API.Catches += 1
            API.RetryCount=0
            API.LastError=nil
        end
        ownedCast, sessionId = false, nil
    end
end)

connections[#connections + 1] = RunService.Heartbeat:Connect(function()
    if not destroyed and os.clock()-lastConfigCheck>=0.2 then
        lastConfigCheck=os.clock()
        local diagnostics={WARN=API.LastWarning,PROTECT=API.Protection.State,SERVER=API.Protection.HopState}
        for category,value in pairs(diagnostics) do
            if value and value~=lastDiagnostics[category] then
                lastDiagnostics[category]=value
                logEvent(category,value,"diagnostic-"..category,0.5)
            end
        end
        if Config.Enabled and not API.ProtectionActive and not API.Running and not API.WorkerActive
            and os.clock()>=(API.NextRetryAt or 0) then API.Start()
        elseif not Config.Enabled and API.Running then API.Stop("Disabled in Config") end
    end
    if os.clock()-lastPopupSweep>0.5 then
        lastPopupSweep=os.clock()
        pcall(cancelPurchasePrompts)
    end
    if os.clock()-lastRespawnCheck>=0.2 then
        lastRespawnCheck=os.clock()
        pcall(autoRespawn)
    end
    if API.Running and API.Travelling and API.Transport~="Swimming" then
        local stamina = Sprint.sprint_bar.get()
        if not Sprint.sprinting.get() and stamina > 0.3 then Sprint.sprinting.set(true) end
        if Sprint.sprinting.get() and stamina < 0.05 then Sprint.sprinting.set(false) end
    end
    if not API.Running or not ownedCast or not Slider.enabled.get() then return end
    local level = Slider.level.get()
    local now = os.clock()
    if pendingLevel == level and now - pendingAt < 1.6 then return end
    if now - lastClick < 0.12 then return end
    local needle, target, size = Slider.needle_pos.get(), Slider.target_pos.get(), Slider.target_size.get()
    -- Click inside the actual visible target; do not fabricate wins or session IDs.
    if math.abs(needle - target) <= size * 0.28 then
        lastClick, pendingAt, pendingLevel = now, now, level
        local ok, err = pcall(click)
        if not ok then API.Retry("Slider handler failed: "..tostring(err)) end
    end
end)

function API.Start()
    if env.BlockSpinSkyLanding then status("Finishing gradual sky landing") return end
    Config.Enabled = true
    if os.clock()<(API.NextRetryAt or 0) then return end
    if API.ProtectionActive then return end
    if destroyed or API.Running then return end
    if API.WorkerActive then status("Finishing previous action; Config will retry") return end
    if env.DIBUConfig and env.DIBUConfig.AutoFarm then
        status("Stop DIBU Auto Farm using its toggle; Config will retry")
        return
    end
    API.Running = true
    API.NextRetryAt=nil
    API.NeedsRespawnRecovery=false
    API.LastError=nil
    API.WorkerActive=true
    generation += 1
    local token = generation
    task.spawn(function()
        local ok, err = pcall(function()
            if not enterGame(token) then return end
            if not API.Protection.BeforeStart(token) then return end
            local handlerDeadline=os.clock()+60
            repeat
                click=filtergc("function",{Name="handle_click",Constants={"minigame_click"}},true)
                if click then break end
                status("Waiting for fishing input to initialize")
                task.wait(0.25)
            until not alive(token) or os.clock()>handlerDeadline
            if not alive(token) then return end
            if type(click)~="function" then error("Fishing input did not initialize after startup") end
            -- Unequipping runs the game's own cancellation path for any previous script's cast.
            local _,initialHumanoid=character()
            if initialHumanoid then initialHumanoid:UnequipTools() task.wait(0.3) end
            while alive(token) do
                local _, h, root = character()
                if not h or h.Health <= 0 or h:GetAttribute("IsDead")==true or not root then
                    cancelOwnedCast()
                    if driveCleanup then driveCleanup() end
                    Sprint.sprinting.set(false)
                    if not Config.ResumeAfterDeath then API.Stop("Character unavailable") return end
                    status("Waiting for respawn")
                    local respawned=waitFor(token,function()
                        local _,hum,part=character()
                        return hum and part and hum.Health>0 and hum:GetAttribute("IsDead")~=true
                    end,90)
                    if not respawned then API.Retry("Respawn timed out") return end
                    API.ZoneSkill=nil
                    API.OnIsland=false
                    continue
                end
                updateProgress()
                if not recoverDeathDrops(token) then return end
                if not ensureStartupKit(token) then return end
                if Config.AutoPickupDrops then
                    local _,_,lootRoot=character()
                    if lootRoot and not collectDrops(token,lootRoot.Position,Config.LootRadius) then return end
                    if not deposit(token) then return end
                end
                selectZone()
                local manualSale=API.SellRequested==true
                if inventoryFull() or manualSale then
                    API.SellRequested=false
                    if fishCount()>0 then if not sellFish(token,manualSale) then return end
                    elseif inventoryFull() then error("Inventory full of non-fish items") end
                end
                if not ensureCarCrate(token) then return end
                if not ensureBike(token) then return end
                if not API.ZoneSkill then selectZone() end
                if not alive(token) or not prepareEquipment(token) then return end
                if inventoryFull() then continue end
                if (root.Position - API.Spot).Magnitude > 10 or (API.CenterFishing and not API.AtLakeCenter) then
                    local arrived, why = walkToSpot(token)
                    if not arrived then if alive(token) then API.Retry(why or "Movement route blocked") end return end
                end
                activeRod = equipRod()
                if not activeRod then API.StartupKitReady=false API.Retry("Fishing rod is missing; returning to equipment preparation") return end
                local object = RodModule.class.find(activeRod)
                if not object then task.wait(0.3) continue end
                -- Do not take over a cast started by another script.
                if object.states.has_thrown.get() and not ownedCast then
                    status("Waiting for the previous cast to finish")
                    task.wait(0.5)
                    continue
                end
                if not ownedCast and not Slider.enabled.get() then
                    local loaded, why = loadBait(activeRod)
                    if not loaded then API.Retry(why or "Bait loading failed") return end
                    if not alive(token) then return end
                    status("Casting")
                    ownedCast = true
                    object.states.bobber_position.set(API.Water)
                    object.states.has_thrown.set(true)
                    local accepted, message, reason
                    if API.SkyFishing then
                        local startIndex=(API.SkyCastIndex or 0)%2
                        for attempt=0,1 do
                            local index=(startIndex+attempt)%2
                            local castWater=API.CenterWater+Vector3.new(index*4,0,0)
                            API.CastWater=castWater
                            API.Water=castWater+Vector3.new(0,2,0)
                            object.states.bobber_position.set(API.Water)
                            object.states.has_thrown.set(true)
                            accepted,message,reason=netGet("throw_rod",activeRod,castWater)
                            if accepted then API.SkyCastIndex=(index+1)%2 break end
                            object.states.has_thrown.set(false)
                            if not alive(token) then break end
                            task.wait(0.25)
                        end
                    else
                        accepted,message,reason=netGet("throw_rod",activeRod,API.CastWater or API.Water)
                    end
                    API.LastCastResult={Accepted=accepted,Message=message,Reason=reason}
                    if not alive(token) then cancelOwnedCast() return end
                    if not accepted then
                        ownedCast = false
                        object.states.has_thrown.set(false)
                        if API.SkyFishing then
                            API.LastSkyCastRejected=true
                            API.LastWarning="Sky cast rejected; returning to surface fishing in the same area"
                            Config.SkyFishing=false
                            API.ZoneSkill=nil
                            selectZone()
                            continue
                        end
                        if API.ZoneSkill ~= "LilPond" then
                            rejectedZones[API.ZoneSkill] = true
                            API.ZoneSkill = nil
                            API.LastZoneRejection = tostring(message)
                            selectZone()
                            task.wait(1)
                            continue
                        end
                        API.Retry(tostring(message or "Server rejected this cast"))
                        return
                    end
                    local deadline = os.clock() + 90
                    while alive(token) and ownedCast do
                        status(Slider.enabled.get() and "Reeling - timing the slider" or "Waiting for a bite")
                        if cash()>=Config.DepositThreshold and os.clock()>=(API.NextDepositAttempt or 0) then cancelOwnedCast() break end
                        if os.clock() > deadline then cancelOwnedCast() status("Cast timed out; retrying") break end
                        task.wait(0.2)
                    end
                    task.wait(1.2)
                else
                    task.wait(0.2)
                end
            end
        end)
        API.WorkerActive=false
        if not ok and alive(token) then
            local _,humanoid=character()
            if Config.ResumeAfterDeath and (not humanoid or humanoid.Health<=0 or humanoid:GetAttribute("IsDead")==true or API.NeedsRespawnRecovery) then
                cancelOwnedCast()
                if driveCleanup then driveCleanup() end
                Sprint.sprinting.set(false)
                status("Waiting for respawn")
                local returned=waitFor(token,function()
                    local _,hum,part=character()
                    return hum and part and hum.Health>0 and hum:GetAttribute("IsDead")~=true
                end,90)
                if returned and alive(token) then
                    API.Running=false
                    API.NeedsRespawnRecovery=false
                    API.OnIsland=false
                    API.ZoneSkill=nil
                    API.Start()
                    return
                end
            end
            API.LastError = tostring(err)
            API.Retry(tostring(err):sub(1,300))
        elseif ok and alive(token) then
            API.Retry("Action ended without completion; resuming automatically")
        end
    end)
end
function API.Destroy()
    startup.Cancelled=true
    if startup.TeleportConnection then startup.TeleportConnection:Disconnect() startup.TeleportConnection=nil end
    API.Stop("Closed")
    destroyed = true
    for _, c in ipairs(connections) do c:Disconnect() end
    for _, hook in ipairs(dataHooks) do hook.unhook() end
    if env.BlockSpinAutoFishing == API then
        if env.BlockSpinStatusUI then env.BlockSpinStatusUI.Destroy() end
        env.BlockSpinAutoFishing = nil
    end
end
logEvent("STARTUP","Initialization complete; Enabled="..tostring(Config.Enabled))
if Config.Enabled then API.Start() end
