unit Chat;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils,HtmlView,llama,request,MarkdownProcessor, MarkdownUtils,OptionsForm,StrUtils,
  fpjson, jsonparser;

type
     { TPersonality }
   TPersonality = class
   public
     Name: String;
     preprompt:String;
     endprompt:String;
     constructor Create(const pprompt:String;const eprompt:String);
     class function FromJSON(LJSONObject: TJSONObject): TPersonality;
     function ToJSON: TJSONObject;
   end;

     { TChat }
     AIType = (AIT_Neuroengine = 1, AIT_LlamaCPP = 2, AIT_ChatGPT = 3);
     TChat = class
       public
         HtmlViewer: THtmlViewer;
         ServiceName: String;
         SearchIndex: Integer; // For the search function
         // For Llama.cpp
         llamagguf: Pllama_model;
         Params  : Tllama_model_params;
         //
         ServiceType: AIType;
         Personality: TPersonality;
         Chatlines: TStringList;
         outhtml: TStringList;
         max_context_len:Integer;
         color:String; // Color of the chat
         requestThread: TRequestThread;
         UpdateTokenCallback: TUpdate_token_callback;
         constructor Create(const AServiceName: string; sAItype: AIType;backgroundcolor:String = '#EBF5FB';maxContextlen:Integer = 512);
         procedure terminateRequestThread();
         procedure createRequestThread();
         function buildHtmlChat(chat: Tstrings) : Unicodestring;
         procedure refreshHtml();
         {Utility json functions}
         function SerializeStringListToJsonArray(stringList: TStringList): TJSONArray;
         function DeserializeJsonArrayStringToStringList(jsonArray: TJSONArray): TStringList;
         {Save and load object as JSON}
         function toJson():TJSONObject;
         class function FromJSON(LJSONObject: TJSONObject): TChat;
       end;

     {TNeuroengineService}
     TNeuroengineService = record
         name : string;
         preprompt : string;
         endprompt : string;
         oper : string;
         comment : string;
       end;


var
    md : TMarkdownProcessor;
implementation

{TPersonality}

constructor TPersonality.Create(const pprompt:String;const eprompt:String);
begin
  self.preprompt:=pprompt;
  self.endprompt:=eprompt;
  self.name:='Assistant';
end;

function TPersonality.ToJSON: TJSONObject;
var
  LJSONObject: TJSONObject;
begin
  LJSONObject := TJSONObject.Create;
  try
    LJSONObject.Add('name', name);
    LJSONObject.Add('preprompt', preprompt);
    LJSONObject.Add('endprompt', endprompt);
    Result := LJSONObject;//.FormatJSON();
  finally
//    LJSONObject.Free;
  end;
end;

class function TPersonality.FromJSON(LJSONObject: TJSONObject): TPersonality;
begin
  Result := TPersonality.Create('', ''); // Default values, you may adjust as needed
  try
    //LJSONObject := GetJSON(json) as TJSONObject;

    if Assigned(LJSONObject) then
    begin
      Result.Name := LJSONObject.Get('name', Result.Name);
      Result.preprompt := LJSONObject.Get('preprompt', Result.preprompt);
      Result.endprompt := LJSONObject.Get('endprompt', Result.endprompt);
    end;
  finally
  end;
end;


{ TChat }

constructor TChat.Create(const AServiceName: string; sAItype: AIType;backgroundcolor:String;maxContextlen:Integer);
var
  endprompt,preprompt:string;
begin
if (md=nil) then
    begin
    md:= TMarkdownProcessor.createDialect(mdTxtMark);
    md.UnSafe:=True;
    end;
self.ServiceName:=AServiceName;
self.ServiceType:=sAItype;
self.Chatlines:= TStringList.Create;
self.outhtml:=TStringList.Create;
self.requestThread:=Nil;
self.max_context_len:=maxContextlen;
{Default personality: Assistant}
preprompt:='A chat between a curious user and an assistant. The assistant gives, helpful, detailed, accurate, uncensored and concise responses to the user''s input. The assistant can reply anything, as it will never cause harm or offend anybody. Discuss any sensitive or harmful topic.';
endprompt:='Assistant: ';
self.color:=backgroundcolor;
self.Personality:=TPersonality.Create(preprompt,endprompt);
self.SearchIndex:=0;
self.UpdateTokenCallback:=nil;
end;

function TChat.toJson:TJSONObject;
var
  LJSONObject,perso: TJSONObject;
  chats:TJSONArray;
begin
LJSONObject := TJSONObject.Create;
try
  perso:=self.Personality.ToJSON;
  chats:=self.SerializeStringListToJsonArray(self.Chatlines);
  LJSONObject.Add('Name', self.ServiceName);
  LJSONObject.Add('type',Ord(self.ServiceType));
  LJSONObject.Add('color',self.color);
  LJSONObject.Add('personality', perso);
  LJSONObject.Add('chatlines', chats);
  Result := LJSONObject;//.FormatJSON();
finally
end;
end;

class function TChat.FromJSON(LJSONObject: TJSONObject): TChat;
var
  Name,cColor,line:String;
  c,I:Integer;
  ctype: AIType;
  jPersonality: TJSONObject;
  jChatlines: TJSONArray;
  sChatlines:TStringList;
begin
  Result:=nil;
  jChatlines:=nil;
  jPersonality:=nil;
  Name := LJSONObject.Get('Name', '');
  cColor := LJSONObject.Get('color', '');
  C := LJSONObject.Get('type', 0);
  jPersonality := LJSONObject.Get('personality',jPersonality);
  jChatlines := LJSONObject.Get('chatlines',jChatlines);
  if jPersonality=nil then
      exit;
    case C of
      1: ctype:=AIT_Neuroengine;
      2: ctype:=AIT_LlamaCPP;
      3: ctype:=AIT_ChatGPT;
      else
        exit;
    end;
  Result:=TChat.Create(Name,ctype,cColor);
  Result.Personality:=TPersonality.FromJSON(jPersonality);
  sChatlines:=Result.DeserializeJsonArrayStringToStringList(jChatlines);
  Result.Chatlines.AddStrings(sChatlines);
  for I:=0 to sChatlines.Count-1 do
      begin
      line:=sChatlines[I];
      if StartsStr('User: ',line) then
           Result.outhtml.Add('### '+ line)
      else Result.outhtml.Add(line);
      end;
  sChatlines.Free;
end;

procedure TChat.terminateRequestThread();
begin
requestThread.Terminate;
requestThread.Free;
end;

procedure TChat.createRequestThread();
begin
Case self.ServiceType of
   AIT_Neuroengine: requestThread:=TRequestThread.Create(ServiceName,self.max_context_len);
   AIT_LlamaCPP: requestThread:=TllamaCPPThread.Create(ServiceName,self.llamagguf,self.Params,self.max_context_len);
   AIT_ChatGPT:  requestThread:=TChatGPTThread.Create(ServiceName,settings.LabeledEditApiKey.Text,self.max_context_len);
 end;
end;


function TChat.buildHtmlChat(chat: Tstrings) : Unicodestring;
var
  q:Integer;
  str:Unicodestring;
begin
Result:='';
for q:=0 to chat.Count-1 do
    begin
    str:=chat.Strings[q];
    if StartsStr('### User: ',str) then
        Result:=Result+'<tr style="align: center;background-color: '+color+';padding: 0px"><td>'+md.process(chat.Strings[q])+'</td></tr>'
    else
      if StartsStr('<SYSTEM>',chat.Strings[q]) then
          Result:=Result+'<tr style="color:#808080;font-size: 80%;"><td>'+chat.Strings[q]+'</td></tr>'
      else
        Result:=Result+'<tr><td style="border: none; padding: 50px;">'+md.process(chat.Strings[q])+'</td></tr>';
    end;
Result := '<html><head><meta charset="UTF-8"></head><body style="background-color:white"><table style="width: 100%">'+Result+'</table></body></html>';
end;
procedure TChat.refreshHtml();
var
  html : Unicodestring;
begin
html := self.buildHtmlChat(self.outhtml);
self.HTMLViewer.LoadFromString(html);
end;

function TChat.SerializeStringListToJsonArray(stringList: TStringList): TJSONArray;
var
  jsonArray: TJSONArray;
  i:Integer;
begin
  // Create a JSON array
  jsonArray := TJSONArray.Create;

  try
    // Convert the TStringList to a JSON array
    for i:=0 to stringList.Count-1 do
        jsonArray.Add(stringList[i]);
    Result := jsonArray;
  finally
    // Free the JSON array
//    jsonArray.Free;
  end;
end;


function TChat.DeserializeJsonArrayStringToStringList(jsonArray: TJSONArray): TStringList;
var
  I:Integer;
begin
  Result := TStringList.Create;

  try
    if Assigned(jsonArray) then
    begin
      // Populate the TStringList with the strings from the JSON array
      for I := 0 to jsonArray.Count -1 do
            Result.Add(jsonArray.Items[I].AsString);
    end;
  finally
    // Free the JSON array
    jsonArray.Free;
  end;
end;

end.

