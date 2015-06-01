require 'torch'
require 'cunn'
require 'optim'
require 'image'
require 'paths'
local pl=require 'pl'
bistro = require 'bistro'

----------------------------------------------------------------------
-- parse command-line options
opt = lapp[[
  --dataset          (default "imagenet")      imagenet | lsun
  --model            (default "large")      large | emily | autogen
  -s,--save          (default "imgslogs")      subdirectory to save logs
  --saveFreq         (default 10)          save every saveFreq epochs
  -n,--network       (default "")          reload pretrained network
  -p,--plot                                plot while training
  -r,--learningRateD (default 0.01)        learning rate, for SGD only
  --learningRateG    (default 0.01)        learning rate, for SGD only
  -b,--batchSize     (default 128)         batch size
  -m,--momentum      (default 0)           momentum, for SGD only
  -t,--threads       (default 4)           number of threads
  -d,--noiseDim      (default 100)         dimensionality of noise vector
  --K                (default 1)           number of iterations to optimize D for
  -w, --window       (default 3)           windsow id of sample image
  --nDonkeys         (default 2)           number of data loading threads
  --cache            (default "cache")     folder to cache metadata
  --epochSize        (default 5000)        number of samples per epoch
  --nEpochs          (default 25)
  --coarseSize       (default 16)
  --archgen          (default 1)
]]

print(opt)

opt.manualSeed = torch.random(1,10000) -- fix seed
print("Seed: " .. opt.manualSeed)
torch.manualSeed(opt.manualSeed)
torch.setnumthreads(1)
torch.setdefaulttensortype('torch.FloatTensor')

opt.fineSize = opt.coarseSize * 2
opt.loadSize = opt.coarseSize * 3
opt.noiseDim = {1, opt.fineSize, opt.fineSize}
classes = {'0','1'}
opt.geometry = {3, opt.fineSize, opt.fineSize}
opt.condDim = {3, opt.fineSize, opt.fineSize}
opt.run_id = math.random(1,10000000)

paths.dofile('model.lua')
paths.dofile('data.lua')
adversarial = paths.dofile('train.lua')

-- this matrix records the current confusion across classes
confusion = optim.ConfusionMatrix(classes)

-- Training parameters
sgdState_D = {
  learningRate = opt.learningRateD,
  momentum = opt.momentum
}

sgdState_G = {
  learningRate = opt.learningRateG,
  momentum = opt.momentum
}

local function train()
   print("Training epoch: " .. epoch)
   confusion:zero()
   model_D:training()
   model_G:training()
   batchNumber = 0
   for i=1,opt.epochSize do
      donkeys:addjob(
         function()
            return makeData(trainLoader:sample(opt.batchSize)),
                   makeData(trainLoader:sample(opt.batchSize))
         end,
         adversarial.train)
   end
   donkeys:synchronize()
   cutorch.synchronize()
   print(confusion)
   tr_acc0 = confusion.valids[1] * 100
   tr_acc1 = confusion.valids[2] * 100
   if tr_acc0 ~= tr_acc0 then tr_acc0 = 0 end
   if tr_acc1 ~= tr_acc1 then tr_acc1 = 0 end
end

local function test()
   print("Testing epoch: " .. epoch)
   confusion:zero()
   model_D:evaluate()
   model_G:evaluate()
   for i=1,nTest/opt.batchSize do -- nTest is set in data.lua
      -- xlua.progress(i, math.floor(nTest/opt.batchSize))
      local indexStart = (i-1) * opt.batchSize + 1
      local indexEnd = (indexStart + opt.batchSize - 1)
      donkeys:addjob(function() return makeData(testLoader:get(indexStart, indexEnd)) end,
         adversarial.test)
   end
   donkeys:synchronize()
   cutorch.synchronize()
   print(confusion)
   ts_acc0 = confusion.valids[1] * 100
   ts_acc1 = confusion.valids[2] * 100
   if ts_acc0 ~= ts_acc0 then ts_acc0 = 0 end
   if ts_acc1 ~= ts_acc1 then ts_acc1 = 0 end
end

local function plot(N)
   local N = N or 16
   N = math.min(N, opt.batchSize)
   local offset = 1000
   if opt.dataset == 'lsun' then
      offset = 50
   end
   assert((N * offset) < (nTest - opt.batchSize - 1))
   local noise_inputs = torch.CudaTensor(N, opt.noiseDim[1], opt.noiseDim[2], opt.noiseDim[3])
   local cond_inputs = torch.CudaTensor(N, opt.condDim[1], opt.condDim[2], opt.condDim[3])
   local gt = torch.CudaTensor(N, 3, opt.condDim[2], opt.condDim[3])

   -- Generate samples
   noise_inputs:uniform(-1, 1)
   for i=0,N-1 do
      local indexStart = i * offset + 1
      local indexEnd = (indexStart + opt.batchSize - 1)
      donkeys:addjob(
         function() return makeData(testLoader:get(indexStart, indexEnd)) end,
         function(d) cond_inputs[i+1]:copy(d[3][1]); gt[i+1]:copy(d[4][1]); end
      )
      donkeys:synchronize()
   end
   local samples = model_G:forward({noise_inputs, cond_inputs})

   local to_plot = {}
   for i=1,N do
      local pred = torch.add(cond_inputs[i]:float(), samples[i]:float())
      to_plot[#to_plot+1] = gt[i]:float()
      to_plot[#to_plot+1] = pred
      to_plot[#to_plot+1] = cond_inputs[i]:float()
      to_plot[#to_plot+1] = samples[i]:float()
   end
   to_plot = image.toDisplayTensor{input=to_plot, scaleeach=true, nrow=8}
   if opt.coarseSize < 32 then
      to_plot = image.scale(to_plot, to_plot:size(2) * 32 / opt.coarseSize,
                            to_plot:size(3) * 32 / opt.coarseSize)
   end
   image.save(opt.save .. '/' .. 'gen_' .. epoch .. '.png', to_plot)
   if opt.plot then
      local disp = require 'display'
      disp.image(to_plot, {win=opt.window, width=600})
   end

end

os.execute('mkdir -p ' .. opt.save)

epoch = 1
while epoch < opt.nEpochs do
   train()
   test()
   torch.save(opt.save .. '/' .. 'model_' .. epoch .. '.t7',
              {D = sanitize(model_D), G = sanitize(model_G)})
   bistro.log(merge_table({epoch = opt.epoch,
                           tr_acc0 = tr_acc0,
                           tr_acc1 = tr_acc1,
                           ts_acc0 = ts_acc0,
                           ts_acc1 = ts_acc1,
                           desc_D = desc_D,
                           desc_G = desc_G,
                          }, opt))
   sgdState_D.momentum = math.min(sgdState_D.momentum + 0.0008, 0.7)
   sgdState_D.learningRate = math.max(sgdState_D.learningRate / 1.000004, 0.000001)
   sgdState_G.momentum = math.min(sgdState_G.momentum + 0.0008, 0.7)
   sgdState_G.learningRate = math.max(sgdState_G.learningRate / 1.000004, 0.000001)

   plot(16)
   epoch = epoch + 1
end
