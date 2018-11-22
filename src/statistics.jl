
function getCallResponseTimes(sim::Simulation)
	@assert(sim.complete)
	@assert(all(call -> call.responseTime >= 0, sim.calls))
	return map(call -> call.responseTime, sim.calls)
end

function getAvgCallResponseTime(sim::Simulation; useMinutes::Bool = false)
	@assert(sim.complete)
	@assert(all(call -> call.responseTime >= 0, sim.calls))
	return mean(call -> call.responseTime, sim.calls) * (useMinutes ? 60*24 : 1) # if useMinutes, convert days to minutes
end

function getCallsReachedInTime(sim::Simulation;
	targetResponseTimes::Vector{Float} = sim.targetResponseTimes)
	@assert(sim.complete)
	@assert(all(call -> call.responseTime >= 0, sim.calls))
	return map(call -> call.responseTime <= targetResponseTimes[Int(call.priority)], sim.calls)
end

function countCallsReachedInTime(sim::Simulation;
	targetResponseTimes::Vector{Float} = sim.targetResponseTimes)
	@assert(sim.complete)
	@assert(all(call -> call.responseTime >= 0, sim.calls))
	return count(call -> call.responseTime <= targetResponseTimes[Int(call.priority)], sim.calls)
end

function printSimStats(sim::Simulation)
	printAmbsStats(sim.ambulances)
	println()
	printCallsStats(sim.calls)
end

function printTime(t::Float)
	return string(round(t*24*60, 2), " minutes") # convert days to minutes, round
end

function printAmbsStats(ambulances::Vector{Ambulance})
	numAmbs = length(ambulances)
	travelTimes = [amb.totalTravelTime for amb in ambulances]

	# Gadfly.plot(ecdf(travelTimes*24*60),
		# x="Total travel time (minutes)",
		# y="Cdf")

	println("Ambulance statistics:")

	println("Travel time: ")
	println(" mean = ", printTime(mean(travelTimes)))
	println(" std = ", printTime(std(travelTimes)))
	println(" min = ", printTime(minimum(travelTimes)))
	println(" max = ", printTime(maximum(travelTimes)))
end

function printCallsStats(calls::Vector{Call})
	numCalls = length(calls)
	responseTimes = [call.responseTime == nullTime ? Inf : call.responseTime for call in calls]
	callAnswered = [call.responseTime != nullTime for call in calls] # may be false if sim not finished, or call cancelled

	println("Call statistics:")

	# print, then remove, unanswered calls
	println("Unanswered calls: ", numCalls - sum(callAnswered))

	responseTimes = responseTimes[callAnswered] # no longer consider unanswered calls

	# Gadfly.plot(ecdf(responseTimes*24*60), x="Call response time (minutes)", y="Cdf")

	println("Response time: ")
	println(" mean = ", printTime(mean(responseTimes)))
	println(" std = ", printTime(std(responseTimes)))
	println(" min = ", printTime(minimum(responseTimes)))
	println(" max = ", printTime(maximum(responseTimes)))

end

# calculate batch means of values, with values[i] corresponding with times[i]
# each batch will have duration of batchTime, number of values in each batch is also returned
# batches will be made starting at (and including) startTime, up to (but not including) endTime
# warm-up and cool-down periods should be included by varying the start and end time values
function calcBatchMeans(; values::Vector{Float} = [], times::Vector{Float} = [],
	batchTime::Float = nullTime, startTime::Float = nullTime, endTime::Float = nullTime)
	
	@assert(length(times) == length(values))
	@assert(length(times) >= 1)
	@assert(batchTime != nullTime && batchTime > 0)
	@assert(startTime != nullTime && startTime >= 0)
	@assert(endTime != nullTime && endTime >= startTime)
	
	# calculate number of batches
	numBatches = max(0, Int(floor((endTime - startTime) / batchTime)))
	
	if numBatches == 0
		return [], []
	end
	
	# calculate batch means
	batchTotals = zeros(Float,numBatches) # total of values in each batch
	batchCounts = zeros(Int,numBatches) # total number of values in each batch
	for (i, time) in enumerate(times)
		batchIndex = Int(floor((time - startTime) / batchTime)) + 1
		if batchIndex >= 1 && batchIndex <= numBatches
			batchTotals[batchIndex] += values[i]
			batchCounts[batchIndex] += 1
		end
	end
	@assert(all(batchCounts .> 0))
	batchMeans = batchTotals ./ batchCounts
	
	return batchMeans, batchCounts
end

# calculate statistics on average response time based on batch means
function calcBatchMeanResponseTimes(sim::Simulation;
	batchTime::Float = nullTime, warmUpTime::Float = nullTime, coolDownTime::Float = nullTime)
	
	@assert(sim.complete == true)
	
	# collate data for use by calcBatchMeans function
	n = sim.numCalls
	times = [sim.calls[i].arrivalTime for i = 1:n]
	values = [sim.calls[i].responseTime for i = 1:n]
	
	return calcBatchMeans(; values = values, times = times, batchTime = batchTime,
		startTime = sim.startTime + warmUpTime, endTime = sim.endTime - coolDownTime)
end

# calculate Stats.sem for each row of x
function Stats.sem{T<:Real}(x::Array{T,2})
	return [Stats.sem(x[i,:]) for i = 1:size(x,1)]
end

# For each x[i], plot mean of y[i,:] with two sided confidence interval.
# Assumes that values in y[i,:] are from a normal distribution with unknown standard deviation.
function meanErrorPlot(x::Vector{Float}, y::Array{Float,2}, conf::Float=0.95)
	@assert(length(x) == size(y,1))
	@assert(0 < conf < 1)
	t = StatsFuns.tdistinvcdf(size(y,2)-1, 1-(1-conf)/2) # t-value, for two sided confidence interval
	# StatsFuns.tdistinvcdf(dof, p) # for n samples, dof = n - 1
	return Plots.scatter(x, mean(y,2), yerror=repmat(t*Stats.sem(y), 1, 2),
		xaxis=("x"), yaxis=("y"), m=(:hline), lab="")
end
function meanErrorPlot(x, y, conf::Float=0.95)
	meanErrorPlot(convert(Vector{Float},x), convert(Array{Float,2},y), conf)
end
# plot y values against indices (y[i,:] plotted at x = i)
function meanErrorPlot(y, conf::Float=0.95)
	meanErrorPlot(1:size(y,1), y, conf)
end

# For a vector of values, fit an AR(0) model, and return a p-value for the Durbin-Watson test.
# From wikipedia: "the Durbin–Watson statistic is a test statistic used to detect the presence
# of autocorrelation at lag 1 in the residuals (prediction errors) from a regression analysis".
function calcAR0DurbinWatsonTestPValue{T<:Real}(x::Vector{T})
	xFit = repmat([mean(x)], length(x), 1)
	residuals = x - xFit
	dwTest = HypothesisTests.DurbinWatsonTest(xFit, residuals)
	return HypothesisTests.pvalue(dwTest)
end
