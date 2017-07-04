BEGIN TRANSACTION;

DROP TABLE IF EXISTS user;

CREATE TABLE user(
    id         INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    first_name TEXT    NOT NULL,
    last_name  TEXT,
    username   TEXT    NOT NULL,
    password   TEXT    NOT NULL,
    is_admin   INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX user_idx ON user(username);

DROP TABLE IF EXISTS activity;

CREATE TABLE activity(
    id            INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    user_id       INTEGER NOT NULL REFERENCES user(id),
    class         TEXT    NOT NULL,
    category      TEXT    NOT NULL,
    sub_category  TEXT    NOT NULL,
    paper         TEXT    NOT NULL,
    activity_date TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    score         REAL    NOT NULL
);

COMMIT;
