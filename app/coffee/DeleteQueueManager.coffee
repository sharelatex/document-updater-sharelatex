RedisManager = require "./RedisManager"
ProjectManager = require "./ProjectManager"
logger = require "logger-sharelatex"
metrics = require "./Metrics"
async = require "async"

module.exports = DeleteQueueManager =
    flushAndDeleteOldProjects: (options, callback) ->
        startTime = Date.now()
        count = 0

        flushProjectIfNotModified = (project_id, flushTimestamp, cb) ->
            ProjectManager.getProjectDocsTimestamps project_id, (err, timestamps) ->
                return callback(err) if err?
                if !timestamps?
                    logger.log {project_id}, "skipping flush of queued project - no timestamps"
                    return cb()
                # are any of the timestamps newer than the time the project was flushed?
                for timestamp in timestamps or [] when timestamp > flushTimestamp
                    metrics.inc "queued-delete-skipped"
                    logger.debug {project_id, timestamps, flushTimestamp}, "found newer timestamp, will skip delete"
                    return cb()
                logger.log {project_id, flushTimestamp}, "flushing queued project"
                ProjectManager.flushAndDeleteProjectWithLocks project_id, {skip_history_flush: true}, (err) ->
                    logger.err {project_id, err}, "error flushing queued project"
                    metrics.inc "queued-delete-completed"
                    return cb(null, true)

        flushNextProject = () ->
            now = Date.now()
            if now - startTime > options.timeout
                logger.log "hit time limit on flushing old projects"
                return callback()
            if count > options.limit
                logger.log "hit count limit on flushing old projects"
                return callback()
            cutoffTime = now - options.min_delete_age 
            RedisManager.getNextProjectToFlushAndDelete cutoffTime, (err, project_id, flushTimestamp, queueLength) ->
                return callback(err) if err?
                return callback() if !project_id?
                logger.log {project_id, queueLength: queueLength}, "flushing queued project"
                metrics.globalGauge "queued-flush-backlog", queueLength
                flushProjectIfNotModified project_id, flushTimestamp, (err, flushed) ->
                    count++ if flushed
                    flushNextProject()

        flushNextProject()