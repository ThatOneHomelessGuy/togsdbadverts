/*
	Add color column with codes to convert over to use in chat msg.
	
	FIX COLORS IN INSURGENCY USING TCT CODE
	
	Add in some replacements in msgs? Nextmap, currentmap, timeleft, etc.
*/

#pragma semicolon 1
#pragma dynamic 131072 //increase stack space to from 4 kB to 131072 cells (or 512KB, a cell is 4 bytes).

#include <sourcemod>
#include <regex>
#include <autoexecconfig> //https://github.com/Impact123/AutoExecConfig or http://www.togcoding.com/showthread.php?p=1862459

#define PLUGIN_VERSION "1.3.5"

#pragma newdecls required

ConVar g_cDBUpdateFreq = null;
ConVar g_cHibernateCVar = null;

Database g_oDatabase = null;
ArrayList g_aAdverts = null;
Regex g_oRegexHex;

char g_sServerIP[64] = "";
int g_iTimerValidation = 1;	//validation for if timer is disabled via tdba_updatefreq, or map change validation
int g_iAdvert = -1;	//tracks which advert in the ADT array was last displayed.
bool g_bCSGO = false;
bool g_bIns = false;
bool g_bDBConnInProg = false;

public Plugin myinfo =
{
	name = "TOGs Database Adverts",
	author = "That One Guy",
	description = "Custom server announcements with colors controlled via databases",
	version = PLUGIN_VERSION,
	url = "http://www.togcoding.com"
}

public void OnPluginStart()
{
	char sGameFolder[32], sDescription[64];
	GetGameDescription(sDescription, sizeof(sDescription), true);
	GetGameFolderName(sGameFolder, sizeof(sGameFolder));
	if((StrContains(sGameFolder, "csgo", false) != -1) || (StrContains(sDescription, "Counter-Strike: Global Offensive", false) != -1))
	{
		g_bCSGO = true;
	}
	else if((StrContains(sGameFolder, "insurgency", false) != -1) || StrEqual(sGameFolder, "ins", false) || (StrContains(sDescription, "Insurgency", false) != -1))
	{
		g_bIns = true;
	}
	else
	{
		g_oRegexHex = new Regex("([A-Fa-f0-9]{6})");
	}
	
	AutoExecConfig_SetFile("togsdbadverts");
	AutoExecConfig_CreateConVar("tdba_version", PLUGIN_VERSION, "TOG Database Adverts: Version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	g_cDBUpdateFreq = AutoExecConfig_CreateConVar("tdba_updatefreq", "30.0", "Frequency (seconds) to send advertisements (0 = disabled)?", _, true, 5.0);
	HookConVarChange(g_cDBUpdateFreq, OnCVarChange);
	g_cDBUpdateFreq.FloatValue = GetConVarFloat(g_cDBUpdateFreq);
	if(g_cDBUpdateFreq.FloatValue)
	{
		g_iTimerValidation++;
		CreateTimer(g_cDBUpdateFreq.FloatValue, TimerCB_DisplayAdvert, g_iTimerValidation, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
	}
	
	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
	
	GetServerIP();
	SetDBHandle();
	
	g_aAdverts = new ArrayList(256);
	
	CreateTimer(5.0, TimerCB_GetAds, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

public void OnCVarChange(ConVar hCVar, const char[] sOldValue, const char[] sNewValue)
{
	if(hCVar == g_cHibernateCVar)
	{
		if(GetConVarInt(g_cHibernateCVar) == 1)
		{
			SetConVarInt(g_cHibernateCVar, 0);
		}
	}
	else if(hCVar == g_cDBUpdateFreq)
	{
		g_cDBUpdateFreq.FloatValue = GetConVarFloat(g_cDBUpdateFreq);
		if(g_cDBUpdateFreq.FloatValue)
		{
			g_iTimerValidation++;
			CreateTimer(g_cDBUpdateFreq.FloatValue, TimerCB_DisplayAdvert, g_iTimerValidation, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
		}
	}
}

public void OnConfigsExecuted()
{
	SetDBHandle();
	
	GetServerIP();
	g_cHibernateCVar = FindConVar("sv_hibernate_when_empty");
	if(g_cHibernateCVar != null)
	{
		SetConVarInt(g_cHibernateCVar, 0);
		g_cHibernateCVar.AddChangeHook(OnCVarChange);
	}
}

public Action TimerCB_GetAds(Handle hTimer)
{
	if(g_oDatabase == null)
	{
		return Plugin_Continue;
	}
	GetServerAds();
	return Plugin_Stop;
}

void GetServerIP()
{
	int aArray[4];
	int iLongIP = GetConVarInt(FindConVar("hostip"));
	aArray[0] = (iLongIP >> 24) & 0x000000FF;
	aArray[1] = (iLongIP >> 16) & 0x000000FF;
	aArray[2] = (iLongIP >> 8) & 0x000000FF;
	aArray[3] = iLongIP & 0x000000FF;
	Format(g_sServerIP, sizeof(g_sServerIP), "%d.%d.%d.%d_%i", aArray[0], aArray[1], aArray[2], aArray[3], GetConVarInt(FindConVar("hostport")));
}

public void OnMapStart()
{
	g_iTimerValidation++;
	if(g_cDBUpdateFreq.FloatValue)
	{
		g_iTimerValidation++;
		CreateTimer(g_cDBUpdateFreq.FloatValue, TimerCB_DisplayAdvert, g_iTimerValidation, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
	}
	if(g_oDatabase != null)
	{
		GetServerAds();
	}
}

public Action TimerCB_DisplayAdvert(Handle hTimer, any iTimerValidation)
{
	if(iTimerValidation != g_iTimerValidation)
	{
		return Plugin_Stop;
	}
	
	if(g_aAdverts.Length)
	{
		g_iAdvert++;
		if(g_iAdvert >= g_aAdverts.Length)
		{
			g_iAdvert = 0;
		}
		char sBuffer[256], sColor[10];
		g_aAdverts.GetString(g_iAdvert, sBuffer, sizeof(sBuffer));
		if(g_bCSGO)
		{
			PrintToChatAll(" \x01%s%s", sColor, sBuffer);
		}
		else
		{
			PrintToChatAll("\x01%s%s", sColor, sBuffer);
		}
	}
	
	return Plugin_Continue;
}

void GetServerAds()
{
	g_aAdverts.Clear();
	char sQuery[200];
	Format(sQuery, sizeof(sQuery), "SELECT `svrmsg` FROM `tdba_msgs` WHERE `%s` = 1 ORDER BY `msgorder`;", g_sServerIP);
	g_oDatabase.Query(SQLCallback_ParseAdverts, sQuery, 2);
}

/*
void ConvertColor(char[] sString, int iSize)
{
	if(StrEqual(sString, "", false))
	{
		return;
	}
	
	if(g_bCSGO)
	{
		if(strlen(sString) <= 3)
		{
			switch(StringToInt(sString))
			{
				case 1:
				{
					Format(sString, iSize, "\x01");
				}
				case 2:
				{
					Format(sString, iSize, "\x02");
				}
				case 3:
				{
					Format(sString, iSize, "\x03");
				}
				case 4:
				{
					Format(sString, iSize, "\x04");
				}
				case 5:
				{
					Format(sString, iSize, "\x05");
				}
				case 6:
				{
					Format(sString, iSize, "\x06");
				}
				case 7:
				{
					Format(sString, iSize, "\x07");
				}
				case 8:
				{
					Format(sString, iSize, "\x08");
				}
				case 9:
				{
					Format(sString, iSize, "\x09");
				}
				case 10:
				{
					Format(sString, iSize, "\x0A");
				}
				case 11:
				{
					Format(sString, iSize, "\x0B");
				}
				case 12:
				{
					Format(sString, iSize, "\x0C");
				}
				case 13:
				{
					Format(sString, iSize, "\x0D");
				}
				case 14:
				{
					Format(sString, iSize, "\x0E");
				}
				case 15:
				{
					Format(sString, iSize, "\x0F");
				}
				case 16: //not recommended - messes with formatting
				{
					Format(sString, iSize, "\x10");
				}
			}
		}
	}
	else if(g_bIns)
	{
		if(strlen(sString) <= 3)
		{
			switch(StringToInt(sString))
			{
				case 1:	//white
				{
					Format(sString, iSize, "\x01");
				}
				case 2:	//team
				{
					Format(sString, iSize, "\x03");
				}
				case 3:	//lime
				{
					Format(sString, iSize, "\x04");
				}
				case 4:	//light green
				{
					Format(sString, iSize, "\x05");
				}
				case 5:	//olive
				{
					Format(sString, iSize, "\x06");
				}
				case 6:	//banana yellow
				{
					Format(sString, iSize, "\x11");
				}
				case 7:	//Dark yellow
				{
					Format(sString, iSize, "\x12");
				}
			}
		}
	}
	else
	{
		Format(sString, iSize, "\x07%s", sString);
	}
}*/

public void SQLCallback_ParseAdverts(Handle hOwner, Handle hHndl, const char[] sError, any iValue)
{
	if(hHndl == null)
	{
		SetFailState("Error (%i): %s", iValue, sError);
	}
	
	if(SQL_GetRowCount(hHndl) != 0)
	{
		char sBuffer[256];

		for(int i = 0; i < SQL_GetRowCount(hHndl); i++)
		{
			SQL_FetchRow(hHndl);
			SQL_FetchString(hHndl, 0, sBuffer, sizeof(sBuffer));
			if(!StrEqual(sBuffer, "", false))
			{
				ConvertColors(sBuffer, sizeof(sBuffer));
				g_aAdverts.PushString(sBuffer);
			}
		}
	}
}

void ConvertColors(char[] sMsg, int iSize)
{
	int iPos = StrContains(sMsg, "{COLOR:", false);
	if(iPos != -1)
	{
		if(g_bCSGO)
		{
			char sReplace[11];
			char sReplaceWith[5];
			char sColor[3];
			do
			{
				sReplace = "";
				sColor = "";
				sReplaceWith = "";
				Format(sColor, sizeof(sColor), "%s%s", sColor, sMsg[iPos + 7]);
				Format(sReplace, sizeof(sReplace), "%s%s", sReplace, sMsg[iPos]);
				ReplaceColorCSGO(sColor, sReplaceWith, sizeof(sReplaceWith));
				ReplaceString(sMsg, iSize, sReplace, sReplaceWith, false);
				iPos = StrContains(sMsg, "{COLOR:", false);
			}
			while(iPos != -1);

			Format(sMsg, iSize, " %s", sMsg);
		}
		else if(g_bIns)
		{
			char sReplace[11];
			char sReplaceWith[5];
			char sColor[3];
			do
			{
				sReplace = "";
				sColor = "";
				sReplaceWith = "";
				Format(sColor, sizeof(sColor), "%s%s", sColor, sMsg[iPos + 7]);
				Format(sReplace, sizeof(sReplace), "%s%s", sReplace, sMsg[iPos]);
				ReplaceColorIns(sColor, sReplaceWith, sizeof(sReplaceWith));
				ReplaceString(sMsg, iSize, sReplace, sReplaceWith, false);
				iPos = StrContains(sMsg, "{COLOR:", false);
			}
			while(iPos != -1);
		}
		else
		{
			char sReplace[15];
			char sReplaceWith[10];
			char sColor[7];
			do
			{
				sReplace = "";
				sColor = "";
				sReplaceWith = "";
				Format(sColor, sizeof(sColor), "%s%s", sColor, sMsg[iPos + 7]);
				if(!IsValidHex(sColor))
				{
					LogError("Invalid hex code specified in chat message! Hex code: %s", sColor);
				}
				Format(sReplace, sizeof(sReplace), "%s%s", sReplace, sMsg[iPos]);
				Format(sReplaceWith, sizeof(sReplaceWith), "\x07%s", sColor);
				ReplaceString(sMsg, iSize, sReplace, sReplaceWith, false);
				iPos = StrContains(sMsg, "{COLOR:", false);
			}
			while(iPos != -1);
		}
	}
}

void ReplaceColorCSGO(char[] sColor, char[] sReplaceWith, int iSize)
{
	if(IsNumeric(sColor) == false)
	{
		LogError("Non-numeric color code encountered for CS:GO! Color code: %s", sColor);
		return;
	}
	
	switch(StringToInt(sColor))
	{
		case 1:
		{
			Format(sReplaceWith, iSize, "\x01");
		}
		case 2:
		{
			Format(sReplaceWith, iSize, "\x02");
		}
		case 3:
		{
			Format(sReplaceWith, iSize, "\x03");
		}
		case 4:
		{
			Format(sReplaceWith, iSize, "\x04");
		}
		case 5:
		{
			Format(sReplaceWith, iSize, "\x05");
		}
		case 6:
		{
			Format(sReplaceWith, iSize, "\x06");
		}
		case 7:
		{
			Format(sReplaceWith, iSize, "\x07");
		}
		case 8:
		{
			Format(sReplaceWith, iSize, "\x08");
		}
		case 9:
		{
			Format(sReplaceWith, iSize, "\x09");
		}
		case 10:
		{
			Format(sReplaceWith, iSize, "\x0A");
		}
		case 11:
		{
			Format(sReplaceWith, iSize, "\x0B");
		}
		case 12:
		{
			Format(sReplaceWith, iSize, "\x0C");
		}
		case 13:
		{
			Format(sReplaceWith, iSize, "\x0D");
		}
		case 14:
		{
			Format(sReplaceWith, iSize, "\x0E");
		}
		case 15:
		{
			Format(sReplaceWith, iSize, "\x0F");
		}
		case 16:
		{
			Format(sReplaceWith, iSize, "\x10");
		}
	}
}

void ReplaceColorIns(char[] sColor, char[] sReplaceWith, int iSize)
{
	if(IsNumeric(sColor) == false)
	{
		LogError("Non-numeric color code encountered for Insurgency! Color code: %s", sColor);
		return;
	}
	
	if(strlen(sColor) <= 3)
	{
		switch(StringToInt(sColor))
		{
			case 1:	//white
			{
				Format(sReplaceWith, iSize, "\x01");
			}
			case 2:	//team
			{
				Format(sReplaceWith, iSize, "\x03");
			}
			case 3:	//lime
			{
				Format(sReplaceWith, iSize, "\x04");
			}
			case 4:	//light green
			{
				Format(sReplaceWith, iSize, "\x05");
			}
			case 5:	//olive
			{
				Format(sReplaceWith, iSize, "\x06");
			}
			case 6:	//banana yellow
			{
				Format(sReplaceWith, iSize, "\x11");
			}
			case 7:	//Dark yellow
			{
				Format(sReplaceWith, iSize, "\x12");
			}
		}
	}
}

bool IsValidHex(const char[] sHex)
{
	if(g_oRegexHex.Match(sHex))
	{
		return true;
	}
	return false;
}

void SetDBHandle()
{
	if(!g_bDBConnInProg)
	{
		if(g_oDatabase != null)
		{
			delete g_oDatabase;
			g_oDatabase = null;
		}
		LogMessage("Establishing database connection for togsdbadverts.");
		g_bDBConnInProg = true;
		Database.Connect(SQLCallback_Connect, "togsdbadverts");
	}
}

public void SQLCallback_Connect(Database oDB, const char[] sError, any data)
{
	if(oDB == null)
	{
		SetFailState("Error connecting to database: %s", sError);
	}
	else
	{
		g_oDatabase = oDB;
		g_bDBConnInProg = false;
		
		char sDriver[64], sQuery[600];
		DBDriver oDriver = g_oDatabase.Driver;
		oDriver.GetIdentifier(sDriver, sizeof(sDriver));
		delete oDriver;
		
		LogMessage("Database connection established for togsdbadverts!");
		
		if(StrEqual(sDriver, "sqlite"))
		{
			Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `tdba_msgs` (`id` INT(20) PRIMARY KEY, `svrmsg` VARCHAR(256) NOT NULL, `msgorder` INT(10) NULL)");
		}
		else
		{
			g_oDatabase.SetCharset("utf8mb4");
			g_oDatabase.Query(SQLCallback_Void, "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;", 7);
			Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `tdba_msgs` (`id` INT(20) NOT NULL AUTO_INCREMENT, `svrmsg` VARCHAR(256) NOT NULL, `msgorder` INT(10) NULL, PRIMARY KEY (`id`)) DEFAULT CHARSET='utf8mb4' DEFAULT COLLATE utf8mb4_unicode_ci AUTO_INCREMENT=1");
		}
		g_oDatabase.Query(SQLCallback_Void, sQuery, 1);

		Format(sQuery, sizeof(sQuery), "ALTER TABLE `tdba_msgs` ADD COLUMN `%s` INT(2) NOT NULL DEFAULT 1", g_sServerIP);
		g_oDatabase.Query(SQLCallback_Ignore, sQuery);
	}
}

public void SQLCallback_Void(Handle hOwner, Handle hHndl, const char[] sError, any iValue)
{
	if(hHndl == null)
	{
		SetFailState("Error (%i): %s", iValue, sError);
	}
}

public void SQLCallback_Ignore(Handle hOwner, Handle hHndl, const char[] sError, any data)
{
	//blank callback to ignore errors when column already exists
}

bool IsNumeric(char[] sString)
{
	for(int i = 0; i < strlen(sString); i++)
	{
		if(!IsCharNumeric(sString[i]))
		{
			return false;
		}
	}
	return true;
}

stock void Log(char[] sPath, const char[] sMsg, any ...)
{
	char sLogFilePath[PLATFORM_MAX_PATH], sFormattedMsg[500];
	BuildPath(Path_SM, sLogFilePath, sizeof(sLogFilePath), "logs/%s", sPath);
	VFormat(sFormattedMsg, sizeof(sFormattedMsg), sMsg, 3);
	LogToFileEx(sLogFilePath, sFormattedMsg);
}

/*
CHANGELOG:
	1.0.0
		- Initial creation.
	1.0.1
		- Edit to fix table name.
	1.1.0
		- Added colors to plugin and edited DB table structure accordingly.
	1.2.0
		- Removed ip_list field from database, as it wasnt being used.
		- Converted to new syntax.
		- Removed CVar for database table name.
		- Changed database default to enable newly added msgs for all servers.
	1.3.0
		- Added dynamic replacement of inline colors to support multiple colors in a message.
		- Increased message buffer to allow for inline colors.
		- Removed database field `colorcode` due to adding inline colors.
	1.3.1
		- Added back valid hex code check.
		- Change color selection to use switch statement (more efficient) for CS:GO and use numbers only.
	1.3.2
		- Changed database default char set from latin1 to utf8.
	1.3.3
		- Edit to account for if sv_hibernate_when_empty doesnt exist.
		- Edit to fix error that occurs if no messages apply to the server.
		- Edit to remove leading space if not CSGO.
	1.3.4
		- Edit to database connection to add some checks I use in other plugins. This was added due to a report of multiple simultaneous MySQL connections.
	1.3.5
		- Added database support for utf8mb4, allowing for custom characters.
*/