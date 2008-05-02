package handler;
import db.Version.VersionChange;

class Main extends Handler<Void> {

	var group : db.Group;

	public function dispatch( request : mtwin.web.Request, level ) {
		group = if( App.user == null ) db.Group.manager.search({ name : "offline" },false).first() else App.user.group;
		App.context.dbAccess = group.canAccessDB;

		var part = request.getPathInfoPart(level++);
		switch( part ) {
		case "wiki":
			execute(request,level);
			return;
		case "db":
			if( App.user != null && App.user.group.canAccessDB ) {
				mt.db.Admin.handler();
				return;
			}
		case "file":
			doFile(request.getPathInfoPart(level++));
			return;
		case "":
			part = "index";
		default:
		}
		var path = new List();
		while( part != "" ) {
			path.add(Editor.normalize(part));
			part = request.getPathInfoPart(level++);
		}
		App.prepareTemplate("entry.mtt");
		this.request = request;
		doView(path);
	}

	override function initialize() {
		free("login",doLogin);
		free("map","map.mtt",doMap);
		free("setlang",doSetLang);
		free("history","history.mtt",doHistory);
		free("backlinks","backlinks.mtt",doBackLinks);
		free("register","register.mtt",doRegister);
		free("user","user.mtt",doUser);
		free("edit","entry.mtt",doEdit);
		free("delete",doDelete);
		free("rename",doRename);
		free("title",doTitle);
		free("upload",doUpload);
		free("sublist",doSubList);
		free("restore",doRestore);
		free("logout",doLogout);
		free("search","search.mtt",doSearch);
		free("remoting",doRemoting);
	}

	public static function encodePass( p : String ) {
		return haxe.Md5.encode("some salt with "+p+" and "+p);
	}

	function doLogin() {
		var user = request.get("user");
		var pass = request.get("pass","");
		var url = request.get("url","/");
		var u = db.User.manager.search({ name : user, pass : encodePass(pass) },false).first();
		if( u == null )
			throw Action.Error(url,Text.get.err_unknown_user_pass);
		App.session.setUser(u);
		throw Action.Goto(url);
	}

	function doLogout() {
		App.session.delete();
		throw Action.Goto(request.get("url","/"));
	}

	function getPath() {
		return request.get("path","").split("/");
	}

	public function getEntry( path, lang ) {
		return db.Entry.get(Lambda.map(path,Editor.normalize),lang);
	}

	function getLang() {
		var l = db.Lang.manager.byCode(request.get("lang",""));
		if( l == null ) l = db.Lang.manager.get(App.session.lang,false);
		return l;
	}

	function getEntries( path ) {
		var entries = new List();
		for( l in db.Lang.manager.all(false) )
			entries.add(getEntry(path,l));
		return entries;
	}

	public function getRights( entry : db.Entry ) {
		var p = (entry == null) ? [] : entry.get_path().split("/");
		while( true ) {
			var r = db.GroupRights.manager.getWithKeys({ gid : group.id, path : p.join("/") },false);
			if( r != null )
				return r;
			if( p.pop() == null )
				break;
		}
		return new db.GroupRights(group,"");
	}

	function updateContent( entry : db.Entry ) {
		var editor = createEditor(entry,false);
		var v = db.Version.manager.get(entry.vid);
		db.Dependency.manager.cleanup(entry);
		v.htmlContent = editor.format(v.content);
		v.update();
	}

	function contentChanged( entry : db.Entry ) {
		for( d in db.Dependency.manager.search({ eid : entry.id },false) ) {
			var e2 = d.target;
			if( e2 == null ) e2 = getEntry(d.path.split("/"),entry.lang);
			if( d.subs != null ) {
				var s = db.Dependency.manager.subSignature(e2);
				if( s != d.subs )
					return true;
			} else if( (e2.hasContent() ? e2.get_title() : null) != d.title )
				return true;
		}
		return false;
	}

	function doView( path : List<String> ) {
		// list available contents
		var langs = new Hash();
		var def = null;
		var cur = null;
		for( l in db.Lang.manager.all(false) ) {
			var vid = db.Entry.manager.resolve(path,l);
			if( vid != null ) {
				langs.set(l.code,vid);
				if( l.id == App.session.lang )
					cur = l;
			}
			if( l.code == Config.LANG )
				def = l;
		}
		// force lang
		if( request.exists("lang") )
			cur = db.Lang.manager.byCode(request.get("lang"));

		// force version
		var version = null;
		if( request.exists("version") ) {
			version = db.Version.manager.get(request.getInt("version"),false);
			if( version != null ) {
				if( version.entry.get_path() != path.join("/") )
					version = null;
				else {
					cur = version.entry.lang;
					App.context.oldversion = version.entry.vid != version.id;
				}
			}
		}

		var entry = if( cur != null ) db.Entry.get(path,cur) else db.Entry.get(path,def);

		// check rights
		var r = getRights(entry);
		if( !r.canView )
			throw Action.Error("/wiki/register",Text.get.err_cant_view);
		App.context.rights = r;

		if( version == null )
			version = entry.version;
		var lang = entry.lang;
		App.langFlags = function(l) return langs.exists(l.code);
		App.langSelected = lang;
		if( !entry.hasContent() )
			entry.cleanup();
		else if( contentChanged(entry) )
			updateContent(entry);
		App.context.version = version;
		App.context.entry = entry;
		App.context.rename = request.exists("rename");
	}

	function doHistory() {
		var entry = null;
		var entries = null;
		var user = null;
		var params = "";
		if( request.exists("path") ) {
			var lang = if( request.exists("lang") ) getLang() else null;
			var path = getPath();
			if( lang == null ) {
				entries = getEntries(path);
				entry = entries.first();
			} else {
				entry = getEntry(path,lang);
				entries = new List();
				entries.add(entry);
			}
			App.langSelected = lang;
			App.context.lang = lang;
			App.context.entry = entry;
			params = "path="+entry.get_path() + ((lang == null) ? "" : ";lang="+lang.code);
		} else if( request.exists("user") ) {
			user = db.User.manager.get(request.getInt("user"),false);
			if( user == null )
				throw Action.Error("/wiki/history",Text.get.err_no_such_user);
			App.context.u = user;
			params = "user="+user.id;
		}
		if( !getRights(entry).canView )
			throw Action.Error("/wiki/register",Text.get.err_cant_view);
		if( request.exists("diff") ) {
			var v = db.Version.manager.get(request.getInt("diff"),false);
			if( v != null && v.getChange() == VContent && getRights(v.entry).canView ) {
				var v2 = db.Version.manager.previous(v);
				App.context.diff = {
					v1 : if( v2 == null ) null else v2.id,
					v2 : v.id,
					txt : mtwin.text.Diff.diff(if( v2 == null ) "" else v2.content,v.content),
				};
			}
		}
		var page = request.getInt("page",0);
		if( page < 0 ) page = 0;
		App.context.page = page;
		App.context.history = db.Version.manager.history(entries,user,page * 20,20);
		if( params.length > 0 )
			params += ";";
		App.context.params = params;
	}

	public function createEditor( entry : db.Entry, cache : Bool ) {
		var lang = entry.lang;
		var config = {
			buttons : new Array(),
			text : Text.get.empty_text,
			name : "wikeditor",
			path : entry.get_path().split("/"),
			sid : App.session.sid,
			lang : lang.code,
			titles : new Hash(),
		};
		// fill titles cache
		if( cache )
			for( d in db.Dependency.manager.search({ eid : entry.id },false) ) {
				var e = d.target;
				if( e == null ) e = getEntry(d.path.split("/"),lang);
				config.titles.set(d.path,{ title : e.get_title(), exists : e.hasContent() });
			}

		var e = new Editor(config);
		e.addButton(Text.get.bold,"**");
		e.addButton(Text.get.italic,"//");
		e.addButton(Text.get.code,"''");
		e.addButton("H1","====== "," ======");
		e.addButton("H2","===== "," =====");
		e.addButton("H3","==== "," ====");
		e.addButton(Text.get.link,"[[","]]",Text.get.empty_link_text);
		e.addButton(Text.get.external_link,"[[","]]",Text.get.empty_external_link_text);
		var me = this;
		e.getTitle = function(path:Array<String>) {
			var entry2 = me.getEntry(path,lang);
			var dep = new db.Dependency();
			dep.entry = entry;
			dep.target = entry2;
			dep.path = path.join("/");
			dep.title = entry2.hasContent() ? entry2.get_title() : null;
			dep.insert();
			return dep.title;
		}
		e.getSubLinks = function(path) {
			var entry2 = me.getEntry(path,lang);
			var dep = new db.Dependency();
			dep.entry = entry;
			dep.target = entry2;
			dep.path = path.join("/");
			dep.subs = db.Dependency.manager.subSignature(entry2);
			dep.insert();
			return me.getSubLinks(entry2);
		}
		return e;
	}

	function getExtensions( group : db.Group ) {
		var imgs = if( group.canUploadImage ) ["gif","png","jpg","jpeg"] else [];
		if( group.canUploadSWF ) imgs.push("swf");
		return {
			images : imgs,
			files : group.allowedFiles.split("|").concat(imgs),
		};
	}

	function doEdit() {
		var entry = getEntry(getPath(),getLang());
		var submit = request.exists("submit");
		var editor = createEditor(entry,!submit);
		App.context.edit = true;
		App.context.entry = entry;
		App.context.editor = editor;
		App.langSelected = entry.lang;
		App.langFlags = function(l) return l == entry.lang;
		App.context.extensions = getExtensions(group);

		// check rights for create/edit
		var r = getRights(entry);
		if( !r.canEdit || (!entry.hasContent() && !r.canCreate) )
			throw Action.Error(entry.getURL(),Text.get.err_cant_edit);
		App.context.rights = r;
		App.context.group = group;

		if( !submit )
			return;
		processEdit(entry,editor,request.get("title",entry.name),request.get(editor.content));
		throw Action.Done(entry.getURL(),Text.get.entry_modified);
	}

	public function processEdit( entry : db.Entry, editor : Editor, title : String, content : String ) {
		var entry = if( entry.id == null ) { entry.insert(); entry; } else db.Entry.manager.get(entry.id);
		var oldTitle = entry.title;
		entry.title = StringTools.trim(title);
		if( entry.title == entry.name || entry.title == "" ) entry.title = null;
		if( entry.title != oldTitle ) {
			entry.update();
			var v = new db.Version(entry,App.user);
			v.setChange(VTitle,oldTitle,entry.title);
			v.insert();
		}
		var v = null;
		if( StringTools.trim(content).length == 0 )
			entry.markDeleted(App.user);
		else if( entry.version == null || entry.version.content != content ) {
			v = new db.Version(entry,App.user);
			v.setChange(VContent,content,null);
			v.insert();
			entry.version = v;
			db.Entry.manager.updateSearchContent(entry);
		} else if( entry.vid != null )
			v = db.Version.manager.get(entry.vid);
		if( v != null ) {
			db.Dependency.manager.cleanup(entry);
			v.htmlContent = editor.format(content);
			v.update();
		}
		entry.update();
	}

	function doDelete() {
		// delete for all langs
		var path = getPath();
		for( e in getEntries(path) ) {
			if( e.id == null || e.vid == null )
				continue;
			if( !getRights(e).canDelete )
				throw Action.Error(e.getURL(),Text.get.err_cant_delete);
			var e = db.Entry.manager.get(e.id);
			e.markDeleted(App.user);
			e.update();
			db.Entry.manager.updateSearchContent(e);
			db.Dependency.manager.cleanup(e);
		}
		throw Action.Done("/"+path.join("/"),Text.get.entry_deleted);
	}

	function doRename() {
		var path = request.get("name","").split("/");
		var name = Editor.normalize(path.pop());
		var psrc = getPath();
		if( name == "" )
			throw Action.Error("/"+psrc.join("/"),Text.get.err_cant_rename_entry);
		for( e in getEntries(psrc) )
			if( e.id != null )
				doRenameEntry(e,path,name);
		throw Action.Done("/"+path.join("/"),Text.get.entry_renamed);
	}

	function doRenameEntry( entry : db.Entry, path, name ) {
		// target parent
		var parent = getEntry(path,entry.lang);
		if( parent != null && parent.id == null )
			parent.insert();
		// check rights
		if( !getRights(entry).canDelete )
			throw Action.Error(entry.getURL(),Text.get.err_cant_delete);
		if( !getRights(parent).canCreate )
			throw Action.Error((parent == null)?"/":parent.getURL(),Text.get.err_cant_edit);
		// check that target does not already exists
		if( db.Entry.manager.count({ pid : parent == null ? null : parent.id, name : name }) > 0 )
			throw Action.Error(entry.getURL(),Text.get.err_cant_rename_used);
		// check that we don't create a recursive entry
		var x = parent;
		while( x != null ) {
			if( x == entry )
				throw Action.Error(entry.getURL(),Text.get.err_cant_rename_rec);
			x = x.parent;
		}
		if( name != entry.name || parent != entry.parent ) {
			var old = entry.get_path();
			var oldparent = entry.parent;
			var entry = db.Entry.manager.get(entry.id);
			entry.name = name;
			entry.parent = parent;
			entry.update();
			db.Dependency.manager.renamed(entry);
			if( oldparent != null && parent != oldparent )
				oldparent.cleanup();
			var v = new db.Version(entry,App.user);
			v.setChange(VName,old,entry.get_path());
			v.insert();
		}
	}

	function doMap() {
		var lang = getLang();
		App.langSelected = lang;
		App.context.roots = db.Entry.manager.getRoots(lang);
	}

	function doTitle() {
		var e = getEntry(getPath(),getLang());
		if( e.hasContent() )
			neko.Lib.print(e.get_title());
	}

	function doSubList() {
		var a = getSubLinks(getEntry(getPath(),getLang()));
		neko.Lib.print(haxe.Serializer.run(a));
	}

	function getSubLinks( e : db.Entry ) {
		if( e.id == null )
			return [];
		return Lambda.array(db.Entry.manager.search({ pid : e.id },false).map(function(e) return { url : "/"+e.get_path(), title : e.get_title() }));
	}

	function doFile( fname : String ) {
		var f = db.File.manager.search({ name : fname },false).first();
		if( f == null ) {
			neko.Web.setReturnCode(404);
			neko.Lib.print("404 - File not found '"+fname+"'");
			return;
		}
		var ch;
		try {
			ch = neko.io.File.write(neko.Web.getCwd()+"/file/"+f.name,true);
		} catch( e : Dynamic ) {
			neko.Sys.sleep(0.5); // wait for another process to write ?
			neko.Web.redirect(neko.Web.getURI()+"?retry="+Std.random(1000));
			return;
		}
		ch.write(f.content);
		ch.close();
		neko.Web.redirect(neko.Web.getURI()+"?reload=1");
	}

	static function readBits( s : String, pos : Int, nbits : Int ) {
		var base = pos >> 3;
		var n = 8 - (pos - (base << 3)); // number of bits to keep
		nbits -= n;
		var k = s.charCodeAt(base) & ((1 << n) - 1);
		if( nbits < 0 ) {
			k >>= -nbits;
			nbits = 0;
			return k;
		}
		while( nbits > 0 ) {
			var c = s.charCodeAt(++base);
			if( nbits >= 8 ) {
				k = (k << 8) | c;
				nbits -= 8;
			} else {
				k = (k << nbits) | (c >> (8 - nbits));
				nbits = 0;
			}
		}
		return k;
	}

	static function getSWFHeader( content : String ) {
		var compressed = switch( content.substr(0,3) ) {
		case "CWS": true;
		case "FWS": false;
		default: throw "Invalid SWF";
		}
		var buf;
		if( compressed ) {
			// uncompress a small amount of data
			buf = neko.Lib.makeString(64);
			var bytes = new neko.zip.Uncompress(15);
			bytes.run(content,8,buf,8);
			bytes.close();
		} else
			buf = content;
		var base = 8 * 8;
		var nbits = readBits(buf,base,5);
		base += 5 + nbits;
		var width = readBits(buf,base,nbits);
		base += nbits * 2;
		var height = readBits(buf,base,nbits);
		return { version : content.charCodeAt(4), width : Math.round(width / 20), height : Math.round(height / 20) };
	}

	function doUpload() {
		try {
			var datas = neko.Web.getMultipart(group.maxUploadSize);
			var filename = datas.get("Filename");
			if( filename == null )
				throw "No filename defined";
			if( !~/^[ A-Za-z0-9._-]+$/.match(filename) )
				throw "Invalid filename "+filename;
			var ext = filename.split(".").pop().toLowerCase();
			if( !Lambda.exists(getExtensions(group).files,function(x) return ext == x) )
				throw "Unsupported file extension "+ext;
			var f = db.File.manager.search({ name : filename },false).first();
			var content = datas.get("file");
			if( f != null ) {
				if( !request.exists("rewrite") && content != f.content )
					throw "File "+filename+" already exists with different content";
				f = db.File.manager.get(f.id,true);
			} else {
				f = new db.File();
				f.name = filename;
				f.update = f.insert;
			}
			f.user = App.user;
			f.content = content;
			f.update();
			neko.db.Manager.cnx.commit();
			try neko.FileSystem.deleteFile(neko.Web.getCwd()+"/file/"+filename) catch( e : Dynamic ) {};
			if( ext == "swf" ) {
				var h = getSWFHeader(content);
				filename += ":"+h.width+"x"+h.height;
			}
			neko.Lib.print(haxe.Serializer.run(filename));
		} catch( e : Dynamic ) {
			var s = new haxe.Serializer();
			s.serializeException(Std.string(e));
			neko.Lib.print(s.toString());
		}
	}

	function doSetLang() {
		var lang = db.Lang.manager.search({ code : request.get("lang") },false).first();
		if( lang == null )
			throw Action.Error(request.get("url"),Text.get.err_no_such_lang);
		App.session.lang = lang.id;
		throw Action.Goto(request.get("url")+"?lang="+lang.code);
	}

	function doRestore() {
		var e = getEntry(getPath(),getLang());
		var v = db.Version.manager.get(request.getInt("version"),false);
		if( v == null || v.entry != e || v.getChange() != VContent )
			throw Action.Error(e.getURL(),Text.get.err_cant_restore);
		if( !getRights(e).canEdit )
			throw Action.Error(e.getURL(),Text.get.err_cant_edit);
		var e = db.Entry.manager.get(e.id);
		e.version = v;
		e.update();
		db.Entry.manager.updateSearchContent(e);
		var v = new db.Version(e,App.user);
		v.setChange(VRestore,Std.string(e.vid),null);
		v.insert();
		throw Action.Goto(e.getURL());
	}

	function doBackLinks() {
		var e = getEntry(getPath(),getLang());
		if( !getRights(e).canView )
			throw Action.Error("/",Text.get.err_cant_view);
		App.context.entry = e;
		App.context.backlinks = db.Dependency.manager.getBackLinks(e);
	}

	function doRegister() {
		var login = request.get("login");
		if( login == null )
			return;
		if( db.User.manager.count({ name : login }) > 0 || !~/^[A-Za-z0-9_]+$/.match(login) )
			throw Action.Error("/wiki/register",Text.get.err_user_invalid);
		var u = new db.User();
		u.name = login;
		u.pass = encodePass(request.get("spass"));
		u.realName = request.get("name");
		u.email = request.get("email");
		if( u.email == "" ) u.email = null;
		u.group = db.Group.manager.search({ name : "user" },false).first();
		u.insert();
		throw Action.Done("/wiki/register",Text.get.user_registered);
	}

	function doUser() {
		var u = db.User.manager.search({ name : request.get("name") },false).first();
		if( u == null )
			throw Action.Error("/",Text.get.err_no_such_user);
		App.context.u = u;
	}

	function doSearch() {
		var s = request.get("s","");
		var page = request.getInt("page",0);
		if( page < 0 ) page = 0;
		App.context.page = page;
		App.context.s = s;
		App.context.results = db.Entry.manager.searchExpr(s,page * 50,50);
	}

	public function setupDatabase() {
		// create structure
		mt.db.Admin.initializeDatabase();
		// default lang
		var l = new db.Lang();
		l.code = Config.LANG;
		l.name = "Default";
		l.insert();
		// admin group
		var g = new db.Group("admin");
		var gadmin = g;
		g.canAccessDB = true;
		g.allowedFiles = "zip|gz|tgz|dmg|exe|swf|txt|xml|pdf";
		g.canUploadImage = true;
		g.canUploadSWF = true;
		g.maxUploadSize = 10000000;
		g.insert();
		var r = new db.GroupRights(g,"");
		r.canView = true;
		r.canCreate = true;
		r.canDelete = true;
		r.canEdit = true;
		r.insert();
		// user group
		var g = new db.Group("user");
		g.insert();
		var r = new db.GroupRights(g,"");
		r.canView = true;
		r.canEdit = true;
		r.insert();
		// offline group
		var g = new db.Group("offline");
		g.insert();
		var r = new db.GroupRights(g,"");
		r.canView = true;
		r.insert();
		// create admin user
		var u = new db.User();
		u.name = "admin";
		u.realName = "Admin";
		u.pass = encodePass(Config.get("admin_password"));
		u.group = gadmin;
		u.insert();
	}

	function doRemoting() {
		var serv = new neko.net.RemotingServer();
		serv.addObject("api",new RemotingApi(this));
		if( !serv.handleRequest() )
			throw "Unknown remoting request";
	}

}