\set ON_ERROR_STOP 1

--'-----------------------------------------------------------------
-- The join(VARCHAR) aggregate
--'-----------------------------------------------------------------

CREATE OR REPLACE FUNCTION join_append(VARCHAR, VARCHAR)
RETURNS VARCHAR AS '
DECLARE
    state ALIAS FOR $1;
    value ALIAS FOR $2;
BEGIN
    IF (value IS NULL) THEN RETURN state; END IF;
    IF (state IS NULL) THEN
        RETURN value;
    ELSE
        RETURN(state || '' '' || value);
    END IF;
END;
' LANGUAGE 'plpgsql';

CREATE AGGREGATE join(BASETYPE = VARCHAR, SFUNC=join_append, STYPE=VARCHAR);

--'-----------------------------------------------------------------
-- Populate the albummeta table, one-to-one join with album.
-- All columns are non-null integers, except firstreleasedate
-- which is CHAR(10) WITH NULL
--'-----------------------------------------------------------------

create or replace function fill_album_meta () returns integer as '
declare

   table_count integer;

begin

   table_count := (SELECT count(*) FROM pg_class WHERE relname = ''albummeta'');
   if table_count > 0 then
       raise notice ''Dropping existing albummeta table'';
       drop table albummeta;
   end if;

   raise notice ''Counting tracks'';
   create temporary table albummeta_tracks as select album.id, count(albumjoin.album) 
                from album left join albumjoin on album.id = albumjoin.album group by album.id;

   raise notice ''Counting discids'';
   create temporary table albummeta_discids as select album.id, count(discid.album) 
                from album left join discid on album.id = discid.album group by album.id;

   raise notice ''Counting trmids'';
   create temporary table albummeta_trmids as select album.id, count(trmjoin.track) 
                from album, albumjoin left join trmjoin on albumjoin.track = trmjoin.track 
                where album.id = albumjoin.album group by album.id;

    raise notice ''Finding first release dates'';
    CREATE TEMPORARY TABLE albummeta_firstreleasedate AS
        SELECT  album AS id, MIN(releasedate)::CHAR(10) AS firstreleasedate
        FROM    release
        GROUP BY album;

   raise notice ''Creating albummeta table'';
   create table albummeta as
   select a.id,
            COALESCE(t.count, 0) AS tracks,
            COALESCE(d.count, 0) AS discids,
            COALESCE(m.count, 0) AS trmids,
            r.firstreleasedate
    FROM    album a
            LEFT JOIN albummeta_tracks t ON t.id = a.id
            LEFT JOIN albummeta_discids d ON d.id = a.id
            LEFT JOIN albummeta_trmids m ON m.id = a.id
            LEFT JOIN albummeta_firstreleasedate r ON r.id = a.id
            ;

    ALTER TABLE albummeta ALTER COLUMN id SET NOT NULL;
    ALTER TABLE albummeta ALTER COLUMN tracks SET NOT NULL;
    ALTER TABLE albummeta ALTER COLUMN discids SET NOT NULL;
    ALTER TABLE albummeta ALTER COLUMN trmids SET NOT NULL;
    -- firstreleasedate stays "WITH NULL"

   create unique index albummeta_id on albummeta(id);

   drop table albummeta_tracks;
   drop table albummeta_discids;
   drop table albummeta_trmids;
   drop table albummeta_firstreleasedate;

   return 1;

end;
' language 'plpgsql';

--'-----------------------------------------------------------------
-- Keep rows in albummeta in sync with album
--'-----------------------------------------------------------------

create or replace function insert_album_meta () returns TRIGGER as '
begin
   insert into albummeta (id, tracks, discids, trmids) values (NEW.id, 0, 0, 0);
   return NEW;
end;
' language 'plpgsql';

create or replace function delete_album_meta () returns TRIGGER as '
begin
   delete from albummeta where id = OLD.id;
   return OLD;
end;
' language 'plpgsql';

--'-----------------------------------------------------------------
-- Changes to albumjoin could cause changes to albummeta.tracks
-- and/or albummeta.trmids
--'-----------------------------------------------------------------

create or replace function a_ins_albumjoin () returns trigger as '
begin
    UPDATE  albummeta
    SET     tracks = tracks + 1,
            trmids = trmids + (SELECT COUNT(*) FROM trmjoin WHERE track = NEW.track)
    WHERE   id = NEW.album;

    return NULL;
end;
' language 'plpgsql';
--'--
create or replace function a_upd_albumjoin () returns trigger as '
begin
    if NEW.album = OLD.album AND NEW.track = OLD.track
    then
        return NULL;
    end if;

    UPDATE  albummeta
    SET     tracks = tracks - 1,
            trmids = trmids - (SELECT COUNT(*) FROM trmjoin WHERE track = OLD.track)
    WHERE   id = OLD.album;

    UPDATE  albummeta
    SET     tracks = tracks + 1,
            trmids = trmids + (SELECT COUNT(*) FROM trmjoin WHERE track = NEW.track)
    WHERE   id = NEW.album;

    return NULL;
end;
' language 'plpgsql';
--'--
create or replace function a_del_albumjoin () returns trigger as '
begin
    UPDATE  albummeta
    SET     tracks = tracks - 1,
            trmids = trmids - (SELECT COUNT(*) FROM trmjoin WHERE track = OLD.track)
    WHERE   id = OLD.album;

    return NULL;
end;
' language 'plpgsql';

--'-----------------------------------------------------------------
-- Changes to discid could cause changes to albummeta.discids
--'-----------------------------------------------------------------

create or replace function a_ins_discid () returns trigger as '
begin
    UPDATE  albummeta
    SET     discids = discids + 1
    WHERE   id = NEW.album;

    return NULL;
end;
' language 'plpgsql';
--'--
create or replace function a_upd_discid () returns trigger as '
begin
    if NEW.album = OLD.album
    then
        return NULL;
    end if;

    UPDATE  albummeta
    SET     discids = discids - 1
    WHERE   id = OLD.album;

    UPDATE  albummeta
    SET     discids = discids + 1
    WHERE   id = NEW.album;

    return NULL;
end;
' language 'plpgsql';
--'--
create or replace function a_del_discid () returns trigger as '
begin
    UPDATE  albummeta
    SET     discids = discids - 1
    WHERE   id = OLD.album;

    return NULL;
end;
' language 'plpgsql';

--'-----------------------------------------------------------------
-- Changes to trmjoin could cause changes to albummeta.trmids
--'-----------------------------------------------------------------

create or replace function a_ins_trmjoin () returns trigger as '
begin
    UPDATE  albummeta
    SET     trmids = trmids + 1
    WHERE   id IN (SELECT album FROM albumjoin WHERE track = NEW.track);

    return NULL;
end;
' language 'plpgsql';
--'--
create or replace function a_upd_trmjoin () returns trigger as '
begin
    if NEW.track = OLD.track
    then
        return NULL;
    end if;

    UPDATE  albummeta
    SET     trmids = trmids - 1
    WHERE   id IN (SELECT album FROM albumjoin WHERE track = OLD.track);

    UPDATE  albummeta
    SET     trmids = trmids + 1
    WHERE   id IN (SELECT album FROM albumjoin WHERE track = NEW.track);

    return NULL;
end;
' language 'plpgsql';
--'--
create or replace function a_del_trmjoin () returns trigger as '
begin
    UPDATE  albummeta
    SET     trmids = trmids - 1
    WHERE   id IN (SELECT album FROM albumjoin WHERE track = OLD.track);

    return NULL;
end;
' language 'plpgsql';

--'-----------------------------------------------------------------
-- Set moderation.closetime when each moderation closes
--'-----------------------------------------------------------------

create or replace function before_update_moderation () returns TRIGGER as '
begin

   if (OLD.status = 1 and NEW.status != 1) -- STATUS_OPEN
   then
      NEW.closetime := NOW();
   end if;

   return NEW;

end;
' language 'plpgsql';

--'-----------------------------------------------------------------
-- Ensure release.releasedate is always valid
--'-----------------------------------------------------------------

CREATE OR REPLACE FUNCTION before_insertupdate_release () RETURNS TRIGGER AS '
DECLARE
    y CHAR(4);
    m CHAR(2);
    d CHAR(2);
    teststr VARCHAR(10);
    testdate DATE;
BEGIN
    -- Check that the releasedate looks like this: yyyy-mm-dd
    IF (NOT(NEW.releasedate ~ ''^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$''))
    THEN
        RAISE EXCEPTION ''Invalid release date specification'';
    END IF;

    y := SUBSTR(NEW.releasedate, 1, 4);
    m := SUBSTR(NEW.releasedate, 6, 2);
    d := SUBSTR(NEW.releasedate, 9, 2);

    -- Disallow yyyy-00-dd
    IF (m = ''00'' AND d != ''00'')
    THEN
        RAISE EXCEPTION ''Invalid release date specification'';
    END IF;

    -- Check that the y/m/d combination is valid (e.g. disallow 2003-02-31)
    IF (m = ''00'') THEN m:= ''01''; END IF;
    IF (d = ''00'') THEN d:= ''01''; END IF;
    teststr := ( y || ''-'' || m || ''-'' || d );
    -- TO_DATE allows 2003-08-32 etc (it becomes 2003-09-01)
    -- So we will use the ::date cast, which catches this error
    testdate := teststr;

    RETURN NEW;
END;
' LANGUAGE 'plpgsql';

--'-----------------------------------------------------------------
-- Maintain albummeta.firstreleasedate
--'-----------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_album_firstreleasedate(INTEGER)
RETURNS VOID AS '
BEGIN
    UPDATE albummeta SET firstreleasedate = (
        SELECT MIN(releasedate) FROM release WHERE album = $1
    ) WHERE id = $1;
    RETURN;
END;
' LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION a_ins_release () RETURNS TRIGGER AS '
BEGIN
    EXECUTE set_album_firstreleasedate(NEW.album);
    RETURN NEW;
END;
' LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION a_upd_release () RETURNS TRIGGER AS '
BEGIN
    EXECUTE set_album_firstreleasedate(NEW.album);
    IF (OLD.album != NEW.album)
    THEN
        EXECUTE set_album_firstreleasedate(OLD.album);
    END IF;
    RETURN NEW;
END;
' LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION a_del_release () RETURNS TRIGGER AS '
BEGIN
    EXECUTE set_album_firstreleasedate(OLD.album);
    RETURN OLD;
END;
' LANGUAGE 'plpgsql';

--'-- vi: set ts=4 sw=4 et :
