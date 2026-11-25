local timeline = {}

timeline._MT = {}
timeline._MT.__index = {}

-- index is the number of snapshots currently applied:
--   index == 0            -> the timeline sits at the state before every snapshot
--   index == #snapshots   -> every snapshot is applied
-- backward runs snapshots[index] and then decrements; forward increments first, then runs it.
-- Keeping the index a plain "applied count" is what makes undo/redo stop cleanly at both ends,
-- and what lets addSnapshot drop the redo branch after an undo.
function timeline._MT.__index:forward()
    if self.index < #self.snapshots then
        self.index += 1

        local snapshot = self.snapshots[self.index]

        if snapshot then
            snapshot.forward(snapshot.data)
        end

        return true
    end

    return false
end

function timeline._MT.__index:backward()
    if self.index >= 1 then
        local snapshot = self.snapshots[self.index]

        self.index -= 1

        if snapshot then
            snapshot.backward(snapshot.data)
        end

        return true
    end

    return false
end

function timeline._MT.__index:addSnapshot(snapshot)
    -- Editing after an undo drops the redo branch, so an undone snapshot can never be replayed
    -- against a state that has already moved on
    if self.index < #self.snapshots then
        for i = #self.snapshots, self.index + 1, -1 do
            self.snapshots[i] = nil
        end
    end

    self.index += 1
    self.snapshots[self.index] = snapshot

    if self.limit and self.limit > 0 then
        while #self.snapshots > self.limit do
            table.remove(self.snapshots, 1)

            self.index -= 1
        end
    end

    return true
end

function timeline.create(snapshotLimit)
    local res = {
        _type = "timeline"
    }

    res.snapshots = {}
    res.index = 0
    res.limit = snapshotLimit

    return setmetatable(res, timeline._MT)
end

return timeline
