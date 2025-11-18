-- victorian_compliment.luau
-- Generates elaborate Victorian-era compliments for a named person

xllify.ExcelFunction({
    name = "VictorianCompliment",
    description = "Generates an elaborate, flowery Victorian-era compliment for the named person",
    category = "Fun",
    parameters = {
        { name = "person_name", type = "string", description = "The name of the person to compliment" }
    }
}, function(person_name)
    -- Input validation
    if person_name == nil or person_name == "" then
        error("Pray tell, one must provide a name to bestow such accolades upon!")
    end

    -- Convert to string and trim whitespace
    local name = tostring(person_name):match("^%s*(.-)%s*$")

    if name == "" then
        error("A name of substance is required, dear user!")
    end

    -- Array of Victorian-style compliment templates
    local compliments = {
        "My dearest " .. name .. ", your countenance most resplendent illuminates the very firmament with its radiant splendor!",

        "One cannot help but marvel, " .. name .. ", at your extraordinary faculties of intellect, which shine forth like a beacon of enlightenment in this modern age!",

        "The unparalleled grace and deportment of " .. name .. " would render even the most distinguished members of society quite speechless with admiration!",

        name .. ", your refinement and cultivation of character stand as a testament to the highest achievements of civilized humanity!",

        "It is with the utmost sincerity that I declare " .. name .. " to possess a nobility of spirit that rivals the greatest luminaries of our time!",

        "Dear " .. name .. ", your presence bestows upon us a magnificence so sublime that the very angels themselves must pause in wonder!",

        "The estimable " .. name .. " demonstrates such exemplary virtues and accomplishments as to inspire profound reverence in all who have the privilege of their acquaintance!",

        name .. ", your elegant bearing and distinguished manner mark you as a person of the most exceptional breeding and refinement!",

        "One finds in " .. name .. " such a remarkable combination of wisdom, grace, and magnanimity as to defy all conventional description!",

        "The illustrious " .. name .. " possesses such extraordinary qualities of mind and spirit that one can only regard them with the deepest admiration and respect!",

        "My esteemed " .. name .. ", your sterling character and impeccable taste establish you as a paragon of all that is good and noble in this world!",

        "It must be proclaimed that " .. name .. " exhibits such consummate excellence in all endeavors as to set the very standard by which others must be measured!"
    }

    -- Generate a pseudo-random index based on the name
    -- This ensures the same name gets the same compliment (deterministic)
    local seed = 0
    for i = 1, #name do
        seed = seed + string.byte(name, i)
    end

    -- Use modulo to get an index within range
    local index = (seed % #compliments) + 1

    return compliments[index]
end)
