DROP TABLE ttyrec_offset;

ALTER TABLE ttyrec RENAME TO ttytemp;

CREATE TABLE games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,

  -- These can be extracted from logrecord.
  src TEXT,
  player TEXT,
  gtime TEXT,

  logrecord TEXT,
  ttyrecs TEXT,

  -- '' => non-splat game, 'y' => splat, 'm' => milestone.
  etype TEXT NOT NULL DEFAULT ''
);

INSERT INTO games (logrecord, ttyrecs, etype)
SELECT logrecord, ttyrecs, splat FROM ttytemp;

DROP TABLE ttytemp;

CREATE TABLE ttyrec (
  -- Full URL of ttyrec
  ttyrec TEXT PRIMARY KEY,

  src TEXT,
  player TEXT,

  -- Start time of ttyrec (a Date::Manip date)
  stime TEXT,

  -- End time of ttyrec (a Date::Manip date)
  etime TEXT
);

CREATE TABLE ttyrec_offset (
  id INTEGER UNIQUE,

  ttyrec TEXT,
  offset INTEGER,
  stop_offset INTEGER,  -- Stop playback here.

  seekbefore INTEGER,
  seekafter INTEGER,

  frame BLOB,
  FOREIGN KEY (id) REFERENCES games (id)
);

DELETE FROM played_games;