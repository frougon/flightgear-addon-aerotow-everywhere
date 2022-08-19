#
# Aerotow Everywhere - Add-on for FlightGear
#
# Written and developer by Roman Ludwicki (PlayeRom, SP-ROM)
#
# Copyright (C) 2022 Roman Ludwicki
#
# Aerotow Everywhere is an Open Source project and it is licensed
# under the GNU Public License v3 (GPLv3)
#

#
# Flight Plan object
#
var FlightPlan = {
    #
    # Constants
    #
    FILENAME_FLIGHTPLAN: "aerotown-addon-flightplan.xml",

    #
    # Constructor
    #
    # addon - Addon object
    # message - Message object
    # routeDialog - RouteDialog object
    #
    new: func (addon, message, routeDialog) {
        var obj = { parents: [FlightPlan] };

        obj.addon       = addon;
        obj.message     = message;
        obj.routeDialog = routeDialog;

        obj.addonNodePath = addon.node.getPath();

        obj.wptCount      = 0;
        obj.fpFileHandler = nil; # Handler for wrire flight plan to file
        obj.coord         = nil; # Coordinates for flight plan
        obj.heading       = nil; # AI plane heading
        obj.altitude      = nil; # AI plane altitude

        obj.flightPlanPath = addon.storagePath ~ "/AI/FlightPlans/" ~ FlightPlan.FILENAME_FLIGHTPLAN;

        return obj;
    },

    #
    # Get airport an runway hash where the glider is located.
    #
    # Return hash with "airport" and "runway", otherwise nil.
    #
    getAirportAndRunway: func () {
        var icao = getprop("/sim/airport/closest-airport-id");
        if (icao == nil) {
            me.message.error("Airport code cannot be obtained.");
            return nil;
        }

        var runwayName = getprop("/sim/atc/runway");
        if (runwayName == nil) {
            me.message.error("Runway name cannot be obtained.");
            return nil;
        }

        var airport = airportinfo(icao);

        if (!contains(airport.runways, runwayName)) {
            me.message.error("The " ~ icao ~" airport does not have runway " ~ runwayName);
            return nil;
        }

        var runway = airport.runways[runwayName];

        var minRwyLength = Aircraft.getSelected(me.addon).minRwyLength;
        if (runway.length < minRwyLength) {
            me.message.error(
                "This runway is too short. Please choose a longer one than " ~ minRwyLength ~ " m "
                ~ "(" ~ math.round(minRwyLength * globals.M2FT) ~ " ft)."
            );
            return nil;
        }

        return {
            "airport": airport,
            "runway": runway,
        };
    },

    #
    # Initialize flight plan and set it to property tree
    #
    # Return 1 on successful, otherwise 0.
    #
    initial: func () {
        var location = me.getAirportAndRunway();
        if (location == nil) {
            return 0;
        }

        var aircraft = Aircraft.getSelected(me.addon);

        me.initAircraftVariable(location.airport, location.runway, 0);

        # inittial readonly waypoint
        setprop(me.addonNodePath ~ "/addon-devel/route/init-wpt/heading-change", me.heading);
        setprop(me.addonNodePath ~ "/addon-devel/route/init-wpt/distance-m", 100);
        setprop(me.addonNodePath ~ "/addon-devel/route/init-wpt/alt-change-agl-ft", aircraft.vs / 10);

        # in air
        var wptData = [
            {"hdgChange": 0,   "dist": 5000, "altChange": aircraft.vs * 5},
            {"hdgChange": -90, "dist": 1000, "altChange": aircraft.vs},
            {"hdgChange": -90, "dist": 1000, "altChange": aircraft.vs},
            {"hdgChange": 0,   "dist": 5000, "altChange": aircraft.vs * 5},
            {"hdgChange": -90, "dist": 1500, "altChange": aircraft.vs * 1.5},
            {"hdgChange": -90, "dist": 1000, "altChange": aircraft.vs},
            {"hdgChange": 0,   "dist": 5000, "altChange": aircraft.vs * 5},
            {"hdgChange": 0,   "dist": 0,    "altChange": 0},
            {"hdgChange": 0,   "dist": 0,    "altChange": 0},
            {"hdgChange": 0,   "dist": 0,    "altChange": 0},
        ];

        # Default route
        # ^ - airport with heading direction to north
        # 1 - 1st waypoint
        # 2 - 2nd waypoint, etc.
        #
        #     2 . . 1   7
        #     .     .   .
        #     .     .   .
        #     3     .   .
        #     .     .   .
        #     .     .   .
        #     .     .   .
        #     .     .   .
        #     .     .   .
        #     .     .   .
        #     .     ^   6
        #     .         .
        #     .         .
        #     4 . . . . 5

        var index = 0;
        foreach (var wpt; wptData) {
            setprop(me.addonNodePath ~ "/addon-devel/route/wpt[" ~ index ~ "]/heading-change",    wpt.hdgChange);
            setprop(me.addonNodePath ~ "/addon-devel/route/wpt[" ~ index ~ "]/distance-m",        wpt.dist);
            setprop(me.addonNodePath ~ "/addon-devel/route/wpt[" ~ index ~ "]/alt-change-agl-ft", wpt.altChange);

            index = index + 1;
        }

        me.routeDialog.calculateAltChangeAndTotals();

        return 1;
    },

    #
    # Generate the XML file with the flight plane for our plane for AI scenario.
    # The file will be stored to $Fobj.HOME/Export/aerotown-addon-flightplan.xml.
    #
    # Return 1 on successful, otherwise 0.
    #
    generateXml: func () {
        me.wptCount = 0;

        var location = me.getAirportAndRunway();
        if (location == nil) {
            return 0;
        }

        me.fpFileHandler = io.open(me.flightPlanPath, "w");
        io.write(
            me.fpFileHandler,
            "<?xml version=\"1.0\"?>\n\n" ~
            "<!-- This file is generated automatically by the Aerotow Everywhere add-on -->\n\n" ~
            "<PropertyList>\n" ~
            "    <flightplan>\n"
        );

        var aircraft = Aircraft.getSelected(me.addon);

        me.initAircraftVariable(location.airport, location.runway, 1);

        # Start at 2 o'clock from the glider...
        # Inital ktas must be >= 1.0
        me.addWptGround({"hdgChange": 60, "dist": 25}, {"altChange": 0, "ktas": 5});

        # Reset coord and heading
        me.initAircraftVariable(location.airport, location.runway, 0);

        var gliderOffsetM = me.getGliderOffsetFromRunwayThreshold(location.runway);

        # ... and line up with the runway
        me.addWptGround({"hdgChange": 0, "dist": 30 + gliderOffsetM}, {"altChange": 0, "ktas": 2.5});

        # Rolling
        me.addWptGround({"hdgChange": 0, "dist": 10}, {"altChange": 0, "ktas": 5});
        me.addWptGround({"hdgChange": 0, "dist": 20}, {"altChange": 0, "ktas": 5});
        me.addWptGround({"hdgChange": 0, "dist": 20}, {"altChange": 0, "ktas": aircraft.speed / 6});
        me.addWptGround({"hdgChange": 0, "dist": 10}, {"altChange": 0, "ktas": aircraft.speed / 5});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 4});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 3.5});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 3});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 2.5});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 2});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 1.75});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 1.5});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed / 1.25});
        me.addWptGround({"hdgChange": 0, "dist": 10 * aircraft.rolling}, {"altChange": 0, "ktas": aircraft.speed});

        # Takeof
        me.addWptAir({"hdgChange": 0,   "dist": 100 * aircraft.rolling}, {"elevationPlus": 3, "ktas": aircraft.speed * 1.05});
        me.addWptAir({"hdgChange": 0,   "dist": 100}, {"altChange": aircraft.vs / 10, "ktas": aircraft.speed * 1.025});

        var speedInc = 1.0;
        foreach (var wptNode; props.globals.getNode(me.addonNodePath ~ "/addon-devel/route").getChildren("wpt")) {
            var dist = wptNode.getChild("distance-m").getValue();
            if (dist <= 0.0) {
                break;
            }

            var hdgChange = wptNode.getChild("heading-change").getValue();
            var altChange = aircraft.getAltChange(dist);

            speedInc = speedInc + ((dist / Aircraft.DISTANCE_DETERMINANT) * 0.025);
            var ktas = aircraft.speed * speedInc;
            if (ktas > aircraft.speedLimit) {
                ktas = aircraft.speedLimit;
            }

            me.addWptAir({"hdgChange": hdgChange, "dist": dist}, {"altChange": altChange, "ktas": ktas});
        }

        me.addWptEnd();

        io.write(
            me.fpFileHandler,
            "    </flightplan>\n" ~
            "</PropertyList>\n\n"
        );
        io.close(me.fpFileHandler);

        return 1;
    },

    #
    # Initialize AI aircraft variable
    #
    # airport - Object from airportinfo().
    # runway - Object of runway from which the glider start.
    # isGliderPos - Pass 1 for set AI aircraft's coordinates as glider position, 0 set coordinates as runway threshold.
    #
    initAircraftVariable: func (airport, runway, isGliderPos = 1) {
        var gliderCoord = geo.aircraft_position();

        # Set coordinates as glider position or runway threshold
        me.coord = isGliderPos
            ? gliderCoord
            : geo.Coord.new().set_latlon(runway.lat, runway.lon);

        # Set airplane heading as runway heading
        me.heading = runway.heading;

        # Set AI airplane altitude as glider altitude (assumed it's on the ground).
        # It is more accurate than airport.elevation.
        me.altitude = gliderCoord.alt() * globals.M2FT;
    },

    #
    # Get distance from glider to runway threshold e.g. in case that the user taxi from the runway threshold
    #
    # runway - Object of runway from which the glider start
    # Return the distance in metres, of the glider's displacement from the runway threshold.
    #
    getGliderOffsetFromRunwayThreshold: func (runway) {
        var gliderCoord = geo.aircraft_position();
        var rwyThreshold = geo.Coord.new().set_latlon(runway.lat, runway.lon);

        return rwyThreshold.distance_to(gliderCoord);
    },

    #
    # Add new waypoint on ground
    #
    # coordOffset - Hash for calculate next coordinates (lat, lon), with following fields:
    # {
    #     hdgChange - How the aircraft's heading supposed to change? 0 - keep the same heading.
    #     dis - Distance in meters to calculate next waypoint coordinates.
    # }
    # performance - Hash with following fields:
    # {
    #     altChange - How the aircraft's altitude is supposed to change? 0 - keep the same altitude.
    #     ktas - True air speed of AI plane at the waypoint.
    # }
    #
    addWptGround: func (coordOffset, performance) {
        me.wrireWpt(nil, coordOffset, performance, "ground");
    },

    #
    # Add new waypoint in air
    #
    addWptAir: func (coordOffset, performance) {
        me.wrireWpt(nil, coordOffset, performance, "air");
    },

    #
    # Add "WAIT" waypoint
    #
    # sec - Number of seconds for wait
    #
    addWptWait: func (sec) {
        me.wrireWpt("WAIT", {}, {}, nil, sec);
    },

    #
    # Add "END" waypoint
    #
    addWptEnd: func () {
        me.wrireWpt("END", {}, {});
    },

    #
    # Write waypoint to flight plan file
    #
    # name - The name of waypoint
    # coordOffset.hdgChange - How the aircraft's heading supposed to change?
    # coordOffset.dist - Distance in meters to calculate next waypoint coordinates
    # performance.altChange - How the aircraft's altitude is supposed to change?
    # performance.elevationPlus - Set aircraft altitude as current terrain elevation + given value in feets.
    #                             It's best to use for the first point in the air to avoid the plane collapsing into
    #                             the ground in a bumpy airport
    # performance.ktas - True air speed of AI plane at the waypoint
    # groundAir - Allowed value: "ground or "air". The "ground" means that AI plane is on the ground, "air" - in air
    # sec - Number of seconds for "WAIT" waypoint
    #
    wrireWpt: func (
        name,
        coordOffset,
        performance,
        groundAir = nil,
        sec = nil
    ) {
        var coord = nil;
        if (contains(coordOffset, "hdgChange") and contains(coordOffset, "dist")) {
            me.heading = me.heading + coordOffset.hdgChange;
            if (me.heading < 0) {
                me.heading = 360 + me.heading;
            }

            if (me.heading > 360) {
                me.heading = me.heading - 360;
            }

            me.coord.apply_course_distance(me.heading, coordOffset.dist);
            coord = me.coord;
        }

        var alt = nil;
        if (coord != nil and contains(performance, "elevationPlus")) {
            var elevation = geo.elevation(coord.lat(), coord.lon());
            me.altitude = elevation == nil
                ? me.altitude + performance.elevationPlus
                : elevation * globals.M2FT + performance.elevationPlus;
            alt = me.altitude;
        }
        else if (contains(performance, "altChange")) {
            me.altitude = me.altitude + performance.altChange;
            alt = me.altitude;
        }

        var ktas = contains(performance, "ktas") ? performance.ktas : nil;

        name = name == nil ? me.wptCount : name;
        var data = me.getWptString(name, coord, alt, ktas, groundAir, sec);

        io.write(me.fpFileHandler, data);

        me.wptCount = me.wptCount + 1;
    },

    #
    # Get single waypoint data as a string.
    #
    # name - Name of waypoint. Special names are: "WAIT", "END".
    # coord - The Coord object
    # alt - Altitude AMSL of AI plane
    # ktas - True air speed of AI plane
    # groundAir - Allowe value: "ground or "air". The "ground" means that AI plane is on the ground, "air" - in air
    # sec - Number of seconds for "WAIT" waypoint
    #
    getWptString: func (name, coord = nil, alt = nil, ktas = nil, groundAir = nil, sec = nil) {
        var str = "        <wpt>\n"
                ~ "            <name>" ~ name ~ "</name>\n";

        if (coord != nil) {
            str = str ~ "            <lat>" ~ coord.lat() ~ "</lat>\n";
            str = str ~ "            <lon>" ~ coord.lon() ~ "</lon>\n";
            str = str ~ "            <!-- " ~ coord.lat() ~ "," ~ coord.lon() ~ " -->\n";
        }

        if (alt != nil) {
            # str = str ~ "            <alt>" ~ alt ~ "</alt>\n";
            str = str ~ "            <crossat>" ~ alt ~ "</crossat>\n";
        }

        if (ktas != nil) {
            str = str ~ "            <ktas>" ~ ktas ~ "</ktas>\n";
        }

        if (groundAir != nil) {
            var onGround = groundAir == "ground" ? "true" : "false";
            str = str ~ "            <on-ground>" ~ onGround ~ "</on-ground>\n";
        }

        if (sec != nil) {
            str = str ~ "            <time-sec>" ~ sec ~ "</time-sec>\n";
        }

        return str ~ "        </wpt>\n";
    },
};
