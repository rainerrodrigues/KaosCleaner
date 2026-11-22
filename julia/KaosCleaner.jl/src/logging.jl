# Log records for the host. Julia's @info/@warn (including CSV.jl's parse
# warnings) are buffered here instead of printed to stderr, and the host
# collects them after each call with kaos_take_logs(). Calling back into the
# host while Julia runs is avoided on purpose: CSV.jl logs from its worker
# threads, and a callback that waits on the host's locks (Python's GIL) while
# Julia waits for a garbage collection can deadlock both runtimes.

using Logging

struct BufferLogger <: AbstractLogger
    records::Vector{Tuple{Int, String}}  # (level, message)
    lock::ReentrantLock
end
BufferLogger() = BufferLogger(Tuple{Int, String}[], ReentrantLock())

Logging.min_enabled_level(::BufferLogger) = Logging.Info
Logging.shouldlog(::BufferLogger, level, _module, group, id) = true
Logging.catch_exceptions(::BufferLogger) = true

function Logging.handle_message(logger::BufferLogger, level, message, _module, group, id, file, line; kwargs...)
    text = string(message)
    for (k, v) in kwargs
        text *= " $k=$v"
    end
    lock(() -> push!(logger.records, (Int(level.level), text)), logger.lock)
    return nothing
end

const LOGGER = BufferLogger()

"""
    take_logs!() -> Vector{Tuple{Int, String}}

The buffered records since the last call, oldest first. Levels are Julia's
(Info = 0, Warn = 1000, Error = 2000).
"""
take_logs!() = lock(LOGGER.lock) do
    records = copy(LOGGER.records)
    empty!(LOGGER.records)
    records
end
