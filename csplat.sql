CREATE TABLE logplace (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  logfile TEXT,
  offset INTEGER
);

CREATE INDEX loff ON logplace (logfile, offset);

-- Formerly called 'ttyrec'.
CREATE TABLE games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,

  -- These can be extracted from logrecord.
  src TEXT DEFAULT NULL,
  player TEXT DEFAULT NULL,
  gtime TEXT DEFAULT NULL,

  logrecord TEXT,
  ttyrecs TEXT,

  -- '' => non-splat game, 'y' => splat, 'm' => milestone.
  etype TEXT NOT NULL DEFAULT ''
);

CREATE TABLE ttyrec (
  -- Full URL of ttyrec, translatable to dir.
  ttyrec TEXT PRIMARY KEY,

  src TEXT,
  player TEXT,

  -- Start time of ttyrec (a Date::Manip date)
  stime TEXT,

  -- End time of ttyrec (a Date::Manip date)
  etime TEXT
);

CREATE TABLE played_games (
  ref_id INTEGER,
  FOREIGN KEY (ref_id) REFERENCES ttyrec (id)
);

CREATE TABLE ttyrec_offset (
  id INTEGER UNIQUE,

  ttyrec TEXT,
  offset INTEGER,
  stop_offset INTEGER,  -- Stop playback here.

  seekbefore INTEGER NOT NULL,
  seekafter INTEGER NOT NULL,

  frame BLOB,
  FOREIGN KEY (id) REFERENCES games (id)
);