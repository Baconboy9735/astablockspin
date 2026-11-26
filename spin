-- CONFIG: edit these values before executing. Enabled can also be changed live.
getgenv().BlockSpinFishingConfig = {
    Enabled = true,
    AutoPlay = true,
    AutoSkipTutorial = true,
    AutoSkipAvatar = true,
    AutoPlayTimeout = 90,
    BootstrapWithStocker = true,
    StarterBaitAmount = 5,
    StockerWorkTimeout = 45,
    BankStockerPay = true,
    AutoRespawn = true,
    DepositThreshold = 200,
    BaitPerTrip = 50,
    BaitLowWater = 0,
    AllowPurchaseWithdrawals = true,
    AutoUpgradeRods = true,
    AutoLicense = true,
    ResumeAfterDeath = true,
    EnableDeepSea = true,
    DeepSeaAnchor = nil, -- Optional: Vector3.new(X, Y, Z)
    VehicleSpeed = 42,
    ScooterMinTripDistance = 80,
    ScooterNearbyDistance = 14,
    ScooterCooldownWait = 2,
    ObstaclePollInterval = 0.05,
    BlockedReactionTime = 0.25,
    VaultDuration = 0.65,
    ObstacleNoclip = true,
    NoclipDuration = 0.25,
    NoclipMaxDistance = 8,
    AutoClosePurchases = true,
    LogStatus = false,
}
local Config = getgenv().BlockSpinFishingConfig

-- BlockSpin auto fishing, based on the live session observed on 2026-11-25.
-- Stop DIBU using its own toggle before enabling this script.
-- Uses the game's existing slider click handler and server-authoritative results.
-- Sells fish at capacity, deposits all cash >= 200, and follows fishing unlocks.
-- Withdraws only a purchase shortfall for unlocked rods and bait (user-authorized).

local env = getgenv()
if env.BlockSpinAutoFishing then env.BlockSpinAutoFishing.Destroy() end
if not game:IsLoaded() then game.Loaded:Wait() end
assert(game.PlaceId == 104715542330896 or game.PlaceId == 132247642420063, "This script is for the supported BlockSpin places")
assert(type(filtergc) == "function", "Executor must support filtergc")

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Pathfinding = game:GetService("PathfindingService")
local player = Players.LocalPlayer
local modules = RS.Modules
local Net = require(modules.Core.Net)
local Data = require(modules.Core.Data)
local RodModule = require(modules.Game.ItemTypes.FishingRod)
local Slider = require(modules.Game.Minigames.SliderMinigame)
local Items = require(modules.Game.Inventory.ItemUtils)
local Skills = require(modules.Game.Skills.SkillsList)
local XP = require(modules.Game.Skills.XPFormula)
local FishBuyer = require(modules.Game.Fishing.FishBuyerShared)
local Collection = game:GetService("CollectionService")
local Unlocks = require(modules.Game.Skills.SkillsList.fishing)
local Sprint = require(modules.Game.Sprint)
local Splash = require(modules.Game.SplashScreen)
local Slideshow = require(modules.Game.UI.Slideshow)
local CharacterCreator = require(modules.Game.CharacterCreator.CharacterCreator)
local ShelfStocking = require(modules.Game.Jobs.ShelfStocking)
local JobApplication = require(modules.Game.Jobs.JobApplicationBeacon)
local DeathScreen = require(modules.Game.DeathScreen)
local click = filtergc("function", {Name = "handle_click", Constants = {"minigame_click"}}, true)
local handlerDeadline=os.clock()+30
while not click and os.clock()<handlerDeadline do
    task.wait(0.25)
    click=filtergc("function",{Name="handle_click",Constants={"minigame_click"}},true)
end
assert(type(click) == "function", "Game slider handler not found; game may have changed")

local API = {
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

-- Keep the normal Net API, including its shared sequence counters and game environment.
local netGet = setfenv(function(...) return Net.get(...) end, getfenv(Net.get))
local netSend = setfenv(function(...) return Net.send(...) end, getfenv(Net.send))

local function status(message)
    if Config.LogStatus and API.Status~=message then warn("[AutoFishing] "..message) end
    API.Status = message
end
local lastPopupSweep,lastPopupButton,lastPopupClick=0,nil,0
local lastConfigCheck=0
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
    return not destroyed and API.Running and generation == token
end
local function pressGameButton(button)
    if not button or not button:IsA("GuiButton") or not visible(button) then return false end
    local signal=button.MouseButton1Click
    local listeners=getconnections(signal)
    if #listeners==0 then signal=button.Activated listeners=getconnections(signal) end
    if #listeners==0 then return false end
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
                return true
            end
        else
            readySince=nil
        end
        if os.clock()>deadline then
            API.Stop("Auto Play timed out waiting for the game/character to finish loading")
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
                if screen and screen.Enabled and not playerGui:FindFirstChild("LoadingScreen") and os.clock()-lastPlay>=1.5 then
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
local function cancelOwnedCast()
    if ownedCast and activeRod and activeRod.Parent then
        pcall(netSend, "cancel_throw", activeRod)
    end
    ownedCast, sessionId = false, nil
end
function API.Stop(message)
    Config.Enabled = false
    API.Running = false
    API.Travelling = false
    Sprint.sprinting.set(false)
    if driveCleanup then driveCleanup() end
    if API.EarningForRod and type(ShelfStocking.cancel_stocking)=="function" then ShelfStocking.cancel_stocking() end
    generation += 1
    cancelOwnedCast()
    local _, h, root = character()
    if h and root then h:MoveTo(root.Position) end
    status(message or "Paused")
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
    local function jumpObstacle()
        if h.FloorMaterial == Enum.Material.Air then return end
        h.Jump = true
        h:ChangeState(Enum.HumanoidStateType.Jumping)
    end
    local lastVault = -math.huge
    local function shortNoclip(direction)
        if not Config.ObstacleNoclip or os.clock()-(API.LastNoclipAt or -math.huge)<0.75 then return false end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances={c}
        params.RespectCanCollide=true
        local hit=workspace:Raycast(root.Position,direction*6,params)
            or workspace:Raycast(root.Position-Vector3.new(0,1.8,0),direction*6,params)
        if not hit or hit.Normal.Y>0.65 then return false end
        local overlap=OverlapParams.new()
        overlap.FilterType=Enum.RaycastFilterType.Exclude
        overlap.FilterDescendantsInstances={c}
        overlap.RespectCanCollide=true
        local origin=root.CFrame
        local landing
        -- Find a clear standing position beyond the obstacle, with solid ground.
        for distance=math.max(3,math.ceil(hit.Distance+2)),math.clamp(Config.NoclipMaxDistance,3,10) do
            local point=root.Position+direction*distance
            local floor=workspace:Raycast(point+Vector3.new(0,2,0),Vector3.new(0,-10,0),params)
            if floor and floor.Material~=Enum.Material.Water and floor.Normal.Y>0.6 then
                local candidate=Vector3.new(point.X,floor.Position.Y+h.HipHeight+root.Size.Y/2,point.Z)
                if math.abs(candidate.Y-root.Position.Y)<4
                    and #workspace:GetPartBoundsInBox(CFrame.new(candidate),Vector3.new(3,4.5,3),overlap)==0 then
                    landing=candidate
                    break
                end
            end
        end
        if not landing then return false end
        local saved={}
        for _,part in ipairs(c:QueryDescendants("BasePart")) do saved[part]=part.CanCollide end
        API.LastNoclipAt=os.clock()
        API.NoclipActive=true
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
        if not completed and root.Parent and h.Health>0 then root.CFrame=origin end
        for part,value in pairs(saved) do if part.Parent then part.CanCollide=value end end
        API.NoclipActive=false
        if ok and completed then
            API.NoclipPasses=(API.NoclipPasses or 0)+1
            return true
        end
        return false
    end
    local function vaultShortObstacle(direction)
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
        if clear or not floor or floor.Material==Enum.Material.Water or floor.Position.Y>root.Position.Y+2 then return false end
        lastVault=os.clock()
        -- User-authorized obstacle flight: one short arc, always less than one second.
        local origin=root.Position
        local landing=Vector3.new(landingXZ.X,floor.Position.Y+h.HipHeight+root.Size.Y/2,landingXZ.Z)
        local started=os.clock()
        API.ObstacleFlights=(API.ObstacleFlights or 0)+1
        while alive(token) and os.clock()-started<Config.VaultDuration do
            local alpha=math.min((os.clock()-started)/Config.VaultDuration,1)
            local point=origin:Lerp(landing,alpha)+Vector3.new(0,math.sin(alpha*math.pi)*12,0)
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
    local function reactAhead(direction)
        if h.SeatPart then
            h.Sit=false
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
        local lookAhead=math.clamp(h.WalkSpeed*0.22,4,7)
        local hit=workspace:Raycast(root.Position-Vector3.new(0,1.8,0),direction*lookAhead,sensing)
            or workspace:Raycast(root.Position,direction*lookAhead,sensing)
        if not hit or hit.Normal.Y>0.65 then return false end
        local detected=os.clock()
        if hit.Instance.Name=="DoorBase" then return false end
        local crossed=vaultShortObstacle(direction)
        if crossed then API.LastObstacleResponseTime=os.clock()-detected end
        return crossed
    end
    local function steerOnGround()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = {c}
        params.RespectCanCollide = true
        local stalls = 0
        local visits,previousDirection={},nil
        local function cell(point)
            return tostring(math.floor(point.X/8))..":"..tostring(math.floor(point.Z/8))
        end
        local deadline = os.clock()+math.max(60,horizontal(root.Position,destination)/math.max(h.WalkSpeed,1)*3)
        while alive(token) and (horizontal(root.Position,destination)>4 or math.abs(root.Position.Y-destination.Y)>7) and os.clock()<deadline do
            local steeringDestination=destination
            if horizontal(root.Position,destination)<8 and root.Position.Y>destination.Y+7 then steeringDestination=destination+Vector3.new(45,0,0) end
            local delta = Vector3.new(steeringDestination.X-root.Position.X,0,steeringDestination.Z-root.Position.Z)
            if delta.Magnitude<0.1 then return false end
            local direction = delta.Unit
            local origin = root.Position
            visits[cell(origin)]=(visits[cell(origin)] or 0)+1
            if reactAhead(direction) then stalls=0 continue end
            local best,bestScore,bestDirection
            -- Remember visited cells and allow temporary movement away from the goal.
            for _,degrees in ipairs({0,35,-35,70,-70,100,-100,135,-135,180}) do
                local angle=math.rad(degrees)
                local rotated=Vector3.new(direction.X*math.cos(angle)-direction.Z*math.sin(angle),0,direction.X*math.sin(angle)+direction.Z*math.cos(angle))
                local point=origin+rotated*math.min(12,delta.Magnitude)
                local ground=workspace:Raycast(point+Vector3.new(0,4,0),Vector3.new(0,-25,0),params)
                if ground and ground.Material~=Enum.Material.Water and ground.Normal.Y>0.6 then
                    local obstruction=workspace:Raycast(origin,rotated*math.min(10,delta.Magnitude),params)
                    if not obstruction and ground.Position.Y<=origin.Y+2 then
                        local score=horizontal(ground.Position,steeringDestination)
                            +(visits[cell(ground.Position)] or 0)*24
                            -(previousDirection and previousDirection:Dot(rotated)*3 or 0)
                        if not bestScore or score<bestScore then
                            best,bestScore,bestDirection=ground.Position,score,rotated
                        end
                    end
                end
            end
            if not best then
                jumpObstacle()
                best=origin+direction*5
            end
            previousDirection=bestDirection
            h:MoveTo(best)
            local untilTime=os.clock()+math.max(0.6,horizontal(root.Position,best)/math.max(h.WalkSpeed,1)+0.3)
            local progressPosition,progressAt=root.Position,os.clock()
            repeat
                if not alive(token) or h.Health<=0 then return false end
                local toward=Vector3.new(best.X-root.Position.X,0,best.Z-root.Position.Z)
                if toward.Magnitude>0.1 and reactAhead(toward.Unit) then break end
                if horizontal(root.Position,progressPosition)>0.5 then progressPosition,progressAt=root.Position,os.clock() end
                if os.clock()-progressAt>Config.BlockedReactionTime then
                    jumpObstacle()
                    vaultShortObstacle(direction)
                    break
                end
                task.wait(Config.ObstaclePollInterval)
            until horizontal(root.Position,best)<3 or os.clock()>untilTime
            if horizontal(root.Position,destination) >= horizontal(origin,destination)-1 then
                stalls+=1
                jumpObstacle()
                if stalls>=1 then vaultShortObstacle(direction) end
                if stalls>24 then return false end
            else
                stalls=0
            end
        end
        return horizontal(root.Position,destination)<4 and math.abs(root.Position.Y-destination.Y)<7
    end
    for attempt = 1, 4 do
        if not alive(token) then return false end
        player:RequestStreamAroundAsync(destination, 3)
        local path = Pathfinding:CreatePath({AgentRadius=2, AgentHeight=5, AgentCanJump=true,
            WaypointSpacing=5, Costs={Water=100000}})
        local computed = pcall(function() path:ComputeAsync(root.Position, destination) end)
        if not alive(token) then return false end
        if not computed or path.Status ~= Enum.PathStatus.Success then
            if h:GetState() == Enum.HumanoidStateType.Swimming then
                h:MoveTo(destination)
                h.Jump = true
                local untilTime = os.clock() + 10
                repeat task.wait(0.2) until not alive(token) or os.clock()>untilTime or h:GetState()~=Enum.HumanoidStateType.Swimming
                continue
            end
            if steerOnGround() then return true end
            return false, "Walking route blocked; move around the obstruction and restart"
        end
        local blocked = false
        for _, point in ipairs(path:GetWaypoints()) do
            if not alive(token) or not root.Parent or h.Health<=0 then return false end
            if point.Action == Enum.PathWaypointAction.Jump then h.Jump = true end
            h:MoveTo(point.Position)
            local deadline = os.clock() + math.max(1.2, horizontal(root.Position,point.Position)/math.max(h.WalkSpeed,1)+0.8)
            local progressPosition,progressAt=root.Position,os.clock()
            while horizontal(root.Position,point.Position)>2.8 do
                if not alive(token) or h.Health<=0 then return false end
                local toward=Vector3.new(point.Position.X-root.Position.X,0,point.Position.Z-root.Position.Z)
                if toward.Magnitude>0.1 and reactAhead(toward.Unit) then blocked=true break end
                if horizontal(root.Position,progressPosition)>0.5 then progressPosition,progressAt=root.Position,os.clock() end
                if os.clock()-progressAt>Config.BlockedReactionTime then
                    if toward.Magnitude>0.1 then vaultShortObstacle(toward.Unit) end
                    blocked=true
                    break
                end
                if os.clock()>deadline then blocked=true break end
                task.wait(Config.ObstaclePollInterval)
            end
            if blocked then break end
        end
        if horizontal(root.Position,destination)<4 and math.abs(root.Position.Y-destination.Y)<7 then return true end
        -- Recompute from the current position before using the local detour.
        if blocked and attempt==4 then return steerOnGround(),"Ground detour blocked" end
    end
    return false, "Walking route blocked; move around the obstruction and restart"
end

local walkingRoute = walkToSpot
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
    return route
end
local function tryOwnedTransport(token, destination)
    local c,h,root=character()
    if not root or (root.Position-destination).Magnitude<Config.ScooterMinTripDistance or type(fireproximityprompt)~="function" then return false end
    local owned
    Items.iterate_through_items_of_type(Data,"bike",function(item)
        if item.location=="hand" and item.name=="EScooter" and not item.destroyed and (item.health or 1)>0 then owned=item end
    end)
    if not owned then return false end
    API.Transport="EScooter"
    status("Using inventory EScooter")
    local function findScooter()
        for _,v in ipairs(workspace.Vehicles:GetChildren()) do
            if v.Name=="EScooter" and v:GetAttribute("OwnerUserId")==player.UserId then return v end
        end
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
        local deadline=os.clock()+Config.ScooterCooldownWait
        repeat
            if not alive(token) then return false end
            local accepted,reason=netGet("toggle_equip_item",owned.guid)
            API.LastVehicleReply={Action=action,Accepted=accepted,Reason=reason}
            if accepted then return true end
            if reason~="Cooldown" or os.clock()>=deadline then
                API.LastTransportError=action.." rejected: "..tostring(reason)
                return false
            end
            status("EScooter cooldown - retrying "..action)
            task.wait(0.35)
        until not alive(token)
        return false
    end
    Sprint.sprinting.set(false)
    h:MoveTo(root.Position)
    local existing=findScooter()
    local refreshed=false
    if existing and (existing:GetPivot().Position-root.Position).Magnitude>Config.ScooterNearbyDistance then
        local driver=existing:FindFirstChild("DriverSeat")
        if driver and driver.Occupant and driver.Occupant~=h then API.LastTransportError="Owned scooter is occupied" return false end
        status("Despawning distant EScooter")
        if not toggleScooter("despawn") then return false end
        if not awaitVehicleState(function()return not existing.Parent end,3) then
            API.LastTransportError="Despawn not confirmed; spawn was not attempted"
            return false
        end
        existing=nil
        refreshed=true
    end
    if not existing then
        status("Spawning EScooter beside character")
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
    local seat=vehicle:FindFirstChild("DriverSeat")
    local prompt=vehicle:FindFirstChild("DrivePrompt",true)
    if not seat or not prompt then return false end
    API.LastScooterSpawnDistance=(seat.Position-root.Position).Magnitude
    if (root.Position-seat.Position).Magnitude>10 then
        local reached=walkingRoute(token,seat.Position,"Running to owned EScooter")
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
    local points=roadRoute(root.Position,destination)
    local groundParams=RaycastParams.new()
    groundParams.FilterType=Enum.RaycastFilterType.Include
    groundParams.FilterDescendantsInstances={workspace.Terrain,workspace.Map.RoadNetwork,workspace.Map.Sand}
    groundParams.IgnoreWater=false
    local obstacleParams=RaycastParams.new()
    obstacleParams.FilterType=Enum.RaycastFilterType.Exclude
    local obstacleExclusions={c,vehicle}
    if workspace:FindFirstChild("TerrainDecor") then obstacleExclusions[#obstacleExclusions+1]=workspace.TerrainDecor end
    obstacleParams.FilterDescendantsInstances=obstacleExclusions
    obstacleParams.RespectCanCollide=true
    local bounds,size=vehicle:GetBoundingBox()
    local offset=vehicle:GetPivot().Position.Y-(bounds.Position.Y-size.Y/2)+0.08
    local cleaned=false
    local function cleanup()
        if cleaned then return end
        cleaned=true
        if seat.Parent then seat.ThrottleFloat=0 seat.SteerFloat=0 end
        controls:Enable()
        if h.Parent and h.SeatPart==seat then pcall(netGet,"exit_seat") h.Sit=false end
        driveCleanup=nil
    end
    driveCleanup=cleanup
    status("EScooter - following ground route")
    local drivingOK=true
    for _,point in ipairs(points) do
        local deadline=os.clock()+60
        while alive(token) and seat.Parent and h.SeatPart==seat do
            local pivot=vehicle:GetPivot()
            local delta=Vector3.new(point.X-pivot.Position.X,0,point.Z-pivot.Position.Z)
            if delta.Magnitude<5 then break end
            if os.clock()>deadline then drivingOK=false break end
            local dt=math.min(RunService.Heartbeat:Wait(),0.05)
            if not alive(token) then drivingOK=false break end
            local direction=delta.Unit
            local obstacle=workspace:Raycast(pivot.Position,direction*6,obstacleParams)
            if obstacle and obstacle.Normal.Y<0.65 then
                local landingXZ=pivot.Position+direction*12
                local clear=workspace:Raycast(pivot.Position+Vector3.new(0,13,0),direction*12,obstacleParams)
                local land=workspace:Raycast(landingXZ+Vector3.new(0,15,0),Vector3.new(0,-35,0),groundParams)
                if clear or not land or land.Material==Enum.Material.Water then API.LastTransportError="Obstacle needs ground detour" drivingOK=false break end
                local landing=Vector3.new(landingXZ.X,land.Position.Y+offset,landingXZ.Z)
                local started=os.clock()
                API.ObstacleFlights=(API.ObstacleFlights or 0)+1
                while alive(token) and os.clock()-started<Config.VaultDuration and h.SeatPart==seat do
                    local alpha=math.min((os.clock()-started)/Config.VaultDuration,1)
                    local position=pivot.Position:Lerp(landing,alpha)+Vector3.new(0,math.sin(alpha*math.pi)*12,0)
                    vehicle:PivotTo(CFrame.lookAt(position,position+direction))
                    vehicle.Chassis.AssemblyLinearVelocity=Vector3.zero
                    RunService.Heartbeat:Wait()
                end
                API.LastVaultDuration=os.clock()-started
                if alive(token) then vehicle:PivotTo(CFrame.lookAt(landing,landing+direction)) end
                continue
            end
            local step=pivot.Position+direction*math.min(Config.VehicleSpeed*dt,delta.Magnitude)
            local floor=workspace:Raycast(Vector3.new(step.X,pivot.Position.Y+8,step.Z),Vector3.new(0,-38,0),groundParams)
            if not floor or floor.Material==Enum.Material.Water or math.abs((floor.Position.Y+offset)-pivot.Position.Y)>9 then API.LastTransportError="Road segment has no safe dry ground" drivingOK=false break end
            local position=Vector3.new(step.X,floor.Position.Y+offset,step.Z)
            vehicle:PivotTo(CFrame.lookAt(position,position+direction))
            local chassis=vehicle:FindFirstChild("Chassis")
            if chassis then chassis.AssemblyLinearVelocity=direction*8 chassis.AssemblyAngularVelocity=Vector3.zero end
        end
        if not drivingOK or not alive(token) or h.SeatPart~=seat then break end
    end
    cleanup()
    task.wait(0.5)
    -- Walk/run the final approach; never drive through shop interiors or into water.
    return false
end
local leaveFishBuyer
walkToSpot = function(token,destination,caption)
    destination=destination or API.Spot
    local _,_,travelRoot=character()
    local function inFishShop(point)
        return point.X>-288 and point.X<-236 and point.Z>330 and point.Z<412
    end
    if leaveFishBuyer and travelRoot and inFishShop(travelRoot.Position) and not inFishShop(destination) then
        if not leaveFishBuyer(token) then return false,"Could not exit fish shop" end
    end
    API.Travelling = true
    local ok, reached, reason = pcall(function()
        local mainland=Vector3.new(950,255.3,600)
        local function crossWater(target)
            local _,hum,root=character()
            local deadline=os.clock()+math.max(60,(root.Position-target).Magnitude/7+40)
            local previous,bestProgress=root.Position,os.clock()
            Sprint.sprinting.set(false)
            API.Transport="Swimming"
            while alive(token) and (Vector3.new(root.Position.X-target.X,0,root.Position.Z-target.Z)).Magnitude>5 do
                status("Crossing to/from Deep Sea Island")
                hum:MoveTo(target)
                if (root.Position-previous).Magnitude>3 then previous,bestProgress=root.Position,os.clock() end
                if hum.Health<=0 or os.clock()>deadline or os.clock()-bestProgress>15 then return false,"Island crossing blocked" end
                task.wait(0.4)
            end
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
                local approached,why=walkingRoute(token,mainland,"Running to island crossing")
                if not approached then return false,why end
                local crossed,warning=crossWater(destination)
                if not crossed then return false,warning end
                API.OnIsland=true
            end
            return walkingRoute(token,destination,caption)
        end
        if tryOwnedTransport(token,destination) then return true end
        API.Transport="Running"
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
local function inventoryFull()
    if not capacity or os.clock() - capacityAt > 10 then
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
    local beforeHand, beforeBank = cash(), bank()
    status((from == "hand" and "Depositing $" or "Withdrawing purchase shortfall $") .. amount)
    local accepted, rejection = netGet("transfer_funds", from, to, amount)
    if not accepted and alive(token) then
        local _, _, root = character()
        local nearest, nearestPrompt, distance
        for _, atm in ipairs(Collection:GetTagged("ATM")) do
            if atm:IsDescendantOf(workspace) then
                local prompt=atm:FindFirstChildWhichIsA("ProximityPrompt",true)
                local position = prompt and (prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or prompt.Parent.Position) or atm:GetPivot().Position
                local delta = (position - root.Position).Magnitude
                if prompt and prompt.Enabled and (not distance or delta < distance) then nearest, nearestPrompt, distance = position, prompt, delta end
            end
        end
        if not nearest then error("Bank transfer rejected; no streamed ATM found") end
        local approached=walkToSpot(token,nearest+Vector3.new(0,1,3),"Moving to ATM")
        if not alive(token) then return false end
        -- Re-check with the server even if a nearby collider prevented reaching the exact point.
        API.LastATMApproachCompleted=approached
        if nearestPrompt and type(fireproximityprompt)=="function" then fireproximityprompt(nearestPrompt) task.wait(0.3) end
        accepted, rejection = netGet("transfer_funds", from, to, amount)
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
    if cash() >= Config.DepositThreshold then return transfer(token, "hand", "bank", cash()) end
    return true
end
-- The mainland buyer is indoors; enter through the south double door.
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
        local delta=root.Position-target
        if Vector3.new(delta.X,0,delta.Z).Magnitude<3 then return true end
        task.wait(Config.ObstaclePollInterval)
    end
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
    local inside=p.X>-288 and p.X<-236 and p.Z>330 and p.Z<412
    if not inside then
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
    if root and root.Position.X>-288 and root.Position.X<-236 and root.Position.Z>330 and root.Position.Z<412 then
        if not crossBuyerDoor(token,false) then return false end
        -- Clear the building before planning a long trip north; otherwise a fresh
        -- route can cut straight back through its dining room and east wall.
        if not walkingRoute(token,Vector3.new(-219,255.2,430),"Clearing fish shop patio") then return false end
        return walkingRoute(token,Vector3.new(-219,255.2,320),"Following fish shop side alley")
    end
    return alive(token)
end
local function sellFish(token)
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
    if API.ZoneSkill == chosen.Skill then return end
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
    API.Spot = shore
    API.Water=castWater
    API.ZoneSkill, API.ZoneName = chosen.Skill, chosen.Name
    updateProgress()
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
    if not moveTo(token, Vector3.new(-89,255.5,133.2), "Running to hardware entrance") then return false end
    if not moveTo(token, Vector3.new(-110,255.5,133.2), "Entering hardware store") then return false end
    if not moveTo(token, shop.Position, "Buying " .. name) then return false end
    if not alive(token) then return false end
    local accepted, reason = netGet("purchase_consumable", shop, name, quantity)
    if not accepted then
        deposit(token)
        error("Purchase rejected for " .. name .. ": " .. tostring(reason))
    end
    task.wait(0.4)
    if not alive(token) then return false end
    if not moveTo(token, Vector3.new(-110,255.5,133.2), "Leaving hardware counter") then return false end
    if not moveTo(token, Vector3.new(-89,255.5,133.2), "Leaving hardware store") then return false end
    return true
end
local function hasUsableRod()
    local found=false
    Items.iterate_through_items_of_type(Data,"rod",function(item)
        if item.location=="hand" and (not item.durability or item.durability>0) then found=true end
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
                if kind=="rod" and (not rod or cost<rod.Cost) then rod={Name=name,Cost=cost} end
                if kind=="bait" and name~="Squidtec" and (not bait or cost<bait.Cost) then
                    bait={Name=name,Cost=cost,Ammo=Items.get_item_ammo_type(name)}
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
    status(caption)
    API.Travelling=true
    API.Transport="Running"
    local lastPosition,lastProgress=root.Position,os.clock()
    local deadline=os.clock()+math.max(10,(root.Position-position).Magnitude/7+4)
    while alive(token) do
        local delta=Vector3.new(root.Position.X-position.X,0,root.Position.Z-position.Z).Magnitude
        if delta<1.7 then break end
        if hum.Health<=0 then error("Character died during Stocker travel") end
        hum:MoveTo(position)
        if (root.Position-lastPosition).Magnitude>0.5 then lastPosition,lastProgress=root.Position,os.clock() end
        if os.clock()-lastProgress>1.2 or os.clock()>deadline then
            API.Travelling=false
            return moveTo(token,position,caption)
        end
        task.wait(0.05)
    end
    API.Travelling=false
    Sprint.sprinting.set(false)
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
        if player:GetAttribute("Job")~="shelf_stocker" then error("Shelf Stocker job was lost; restart to reapply") end
        if not jobBox() then
            API.StockerShelf=nil
            if root.Position.X<137 then
                if not stockerStep(token,Vector3.new(130,255.4,root.Position.Z),"Leaving shelf row") then return false end
                if not stockerStep(token,Vector3.new(130,255.4,203),"Leaving shelf aisle") then return false end
            end
            if not stockerStep(token,Vector3.new(145,255.4,203),"Going to stock boxes") then return false end
            if not stockerStep(token,normalBox.Position,"Picking up a normal stock box") then return false end
            fireproximityprompt(prompt)
            if not waitFor(token,function()return jobBox()~=nil end,5) then error("Stock box pickup not confirmed") end
        end
        if not waitFor(token,function()return assignedStockShelf()~=nil end,5) then error("No shelf assigned by server") end
        local shelf=assignedStockShelf()
        if not stockerStep(token,Vector3.new(145,255.4,203),"Carrying stock to the shop") then return false end
        if not stockerStep(token,Vector3.new(130,255.4,203),"Entering shelf aisle") then return false end
        local aisleZ=shelf.Position.Z+shelf.Size.Z/2+2
        if not stockerStep(token,Vector3.new(130,255.4,aisleZ),"Finding assigned shelf row") then return false end
        if not stockerStep(token,Vector3.new(shelf.Position.X,255.4,aisleZ),"Approaching assigned shelf") then return false end
        -- Touching the assigned shelf runs the native timed stocking interaction.
        status("Stocking shelf for fishing equipment")
        hum:MoveTo(Vector3.new(shelf.Position.X,root.Position.Y,shelf.Position.Z))
        local progress=require(modules.Game.UI.ProgressBar)
        local began=waitFor(token,function()return progress.bar_enabled.get() or cash()+bank()>before end,2)
        if not alive(token) then return false end
        if not began and jobBox() and (root.Position-shelf.Position).Magnitude<9 then
            local begin=filtergc("function",{Name="begin_stocking",Upvalues={shelf}},true)
            if begin then task.spawn(begin,root) end
        end
        hum:MoveTo(root.Position)
        local paid=waitFor(token,function()
            if player.Character~=workCharacter or hum.Health<=0 or hum:GetAttribute("IsDead")==true then error("Character died during stocking") end
            return cash()+bank()>before
        end,Config.StockerWorkTimeout)
        if not alive(token) then return false end
        if not paid then error("Stocking cycle did not produce a confirmed payment") end
        API.StockerCycles=(API.StockerCycles or 0)+1
        API.StockerEarned=(API.StockerEarned or 0)+(cash()+bank()-before)
        status(string.format("Starter funds $%d / $%d",starterFunds(),target))
        if Config.BankStockerPay and Config.AllowPurchaseWithdrawals and cash()>0 then
            if not transfer(token,"hand","bank",cash()) then return false end
        elseif cash()>=Config.DepositThreshold and starterFunds()<target then
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
    for _, unlock in ipairs(Unlocks) do
        if unlock.level <= API.Level and unlock.reward_info and unlock.reward_info.tool_name then
            local name = unlock.reward_info.tool_name
            local model = Items.get_item_instance(name)
            if model and model:GetAttribute("FishingItem") == "rod" then desiredRod = name end
            -- Squidtec only works around Deep Sea Island, so keep mainland bait for mainland zones.
            if model and model:GetAttribute("FishingItem") == "bait" and name ~= "Squidtec" then desiredBait = name end
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
    for _,unlock in ipairs(Unlocks) do
        local name=unlock.reward_info and unlock.reward_info.tool_name
        if name and name~="Squidtec" and unlock.level<=API.Level then
            local model=Items.get_item_instance(name)
            if model and model:GetAttribute("FishingItem")=="bait" then
                local ammoType=Items.get_item_ammo_type(name)
                if baitAmount(ammoType)>0 then existingName,existingAmmo=name,ammoType end
            end
        end
    end
    if API.ZoneSkill=="DeepSeaIsland" then
        desiredBait="Squidtec"
        local squid=Items.get_item_ammo_type("Squidtec")
        existingName,existingAmmo=baitAmount(squid)>0 and "Squidtec" or nil,baitAmount(squid)>0 and squid or nil
    end
    if existingAmmo then
        API.BaitName,API.BaitAmmo=existingName,existingAmmo
        return deposit(token)
    end
    if fishCount()>0 then if not sellFish(token) then return false end end
    local ammo = Items.get_item_ammo_type(desiredBait)
    if baitAmount(ammo) <= Config.BaitLowWater and not inventoryFull() then
        local price = Items.get_item_rarity_price(desiredBait)
        local quantity = math.min(Config.BaitPerTrip - baitAmount(ammo), math.floor((cash() + bank()) / price), 50)
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
        if fishCount() > 0 then return sellFish(token) and prepareEquipment(token) end
        error("No bait or funds available; add funds then restart")
    end
    return deposit(token)
end

API.Snapshot = function()
    return {Level = API.Level, XP = API.FishingXP, Zone = API.ZoneName, Bait = API.BaitName,
        Fish = fishCount(), Inventory = Items.get_inventory_count(Data).hand, Capacity = capacity,
        Cash = cash(), Bank = bank(), Sold = API.Sold, Deposited = API.Deposited, Withdrawn = API.Withdrawn,
        Running = API.Running, Status = API.Status, Error = API.LastError, Transport=API.Transport,
        Warning=API.LastWarning, License=Data.has_fishing_license==true, NextUnlock=API.NextUnlock,
        DeepSeaAvailable=API.DeepSeaAvailable,Spot=tostring(API.Spot),Water=tostring(API.Water),
        ObstacleFlights=API.ObstacleFlights or 0,LastVaultDuration=API.LastVaultDuration,
        NoclipPasses=API.NoclipPasses or 0,NoclipActive=API.NoclipActive or false,
        TransportTrips=API.TransportTrips or 0,TransportError=API.LastTransportError,
        ScooterRefreshes=API.ScooterRefreshes or 0,ScooterSpawnDistance=API.LastScooterSpawnDistance,
        VehicleReply=API.LastVehicleReply,ObstaclePollInterval=Config.ObstaclePollInterval,
        LastObstacleResponseTime=API.LastObstacleResponseTime,
        DismissedPrompts=API.DismissedPrompts,LastDismissedPrompt=API.LastDismissedPrompt,
        AutoPlayCompleted=API.AutoPlayCompleted or false,AutoPlayAttempts=API.AutoPlayAttempts or 0,
        AutoAvatarSkipAttempts=API.AutoAvatarSkipAttempts or 0,
        StockerCycles=API.StockerCycles or 0,StockerEarned=API.StockerEarned or 0,
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
        end
        ownedCast, sessionId = false, nil
    end
end)

connections[#connections + 1] = RunService.Heartbeat:Connect(function()
    if not destroyed and os.clock()-lastConfigCheck>=0.2 then
        lastConfigCheck=os.clock()
        if Config.Enabled and not API.Running and not API.WorkerActive then API.Start()
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
        if not ok then API.LastError = tostring(err) API.Stop("Slider handler failed") end
    end
end)

function API.Start()
    Config.Enabled = true
    if destroyed or API.Running then return end
    if API.WorkerActive then status("Finishing previous action; Config will retry") return end
    if env.DIBUConfig and env.DIBUConfig.AutoFarm then
        status("Stop DIBU Auto Farm using its toggle; Config will retry")
        return
    end
    API.Running = true
    API.NeedsRespawnRecovery=false
    API.LastError=nil
    API.WorkerActive=true
    generation += 1
    local token = generation
    task.spawn(function()
        local ok, err = pcall(function()
            if not enterGame(token) then return end
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
                    if not respawned then API.Stop("Respawn timed out") return end
                    API.ZoneSkill=nil
                    API.OnIsland=false
                    continue
                end
                updateProgress()
                if not ensureStarterRod(token) then return end
                selectZone()
                if inventoryFull() or API.SellRequested then
                    API.SellRequested=false
                    if fishCount()>0 then if not sellFish(token) then return end
                    elseif inventoryFull() then error("Inventory full of non-fish items") end
                end
                if not alive(token) or not prepareEquipment(token) then return end
                if inventoryFull() then continue end
                if (root.Position - API.Spot).Magnitude > 10 then
                    local arrived, why = walkToSpot(token)
                    if not arrived then if alive(token) then API.Stop(why) end return end
                end
                activeRod = equipRod()
                if not activeRod then API.Stop("Bring a fishing rod, then restart") return end
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
                    if not loaded then API.Stop(why) return end
                    if not alive(token) then return end
                    status("Casting")
                    ownedCast = true
                    object.states.bobber_position.set(API.Water)
                    object.states.has_thrown.set(true)
                    local accepted, message, reason = netGet("throw_rod", activeRod, API.Water)
                    API.LastCastResult={Accepted=accepted,Message=message,Reason=reason}
                    if not alive(token) then cancelOwnedCast() return end
                    if not accepted then
                        ownedCast = false
                        object.states.has_thrown.set(false)
                        if API.ZoneSkill ~= "LilPond" then
                            rejectedZones[API.ZoneSkill] = true
                            API.ZoneSkill = nil
                            API.LastZoneRejection = tostring(message)
                            selectZone()
                            task.wait(1)
                            continue
                        end
                        API.Stop(tostring(message or "Server rejected this cast"))
                        return
                    end
                    local deadline = os.clock() + 90
                    while alive(token) and ownedCast do
                        status(Slider.enabled.get() and "Reeling - timing the slider" or "Waiting for a bite")
                        if cash() >= Config.DepositThreshold then cancelOwnedCast() break end
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
            API.Stop("Error: " .. tostring(err):sub(1,170))
        end
    end)
end
function API.Destroy()
    API.Stop("Closed")
    destroyed = true
    for _, c in ipairs(connections) do c:Disconnect() end
    for _, hook in ipairs(dataHooks) do hook.unhook() end
    if env.BlockSpinAutoFishing == API then env.BlockSpinAutoFishing = nil end
end
if Config.Enabled then API.Start() end
