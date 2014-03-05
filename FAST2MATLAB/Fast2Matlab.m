function DataOut = Fast2Matlab(FST_file,hdrLines,DataOut)
%% Fast2Matlab
% Function for reading FAST input files in to a MATLAB struct.
%
%
%This function returns a structure DataOut, which contains the following 
% cell arrays:
%.Val              An array of values
%.Label            An array of matching labels
%.HdrLines         An array of the header lines (size specified at input)
%
% The following cell arrays may or may not be part of the DataOut structure
% (depending on the type of file being read):
%.OutList          An array of variables to output
%.OutListComments  An array of descriptions of the .OutList values
%.TowProp          A matrix of tower properties with columns .TowPropHdr 
%.TowPropHdr       A cell array of headers corresponding to the TowProp table
%.BldProp          A matrix of blade properties with columns .BldPropHdr
%.BldPropHdr       A cell array of headers corresponding to the BldProp table
%.DLLProp          A matrix of properties for the Bladed DLL Interface with columns .DLLPropHdr
%.DLLPropHdr       A cell array of headers corresponding to the DLLProp table
%.FoilNm           A Cell array of foil names
%.BldNodesHdr      A cell array of headers corresponding to the BldProp table BldNodes
%.BldNodes         A matrix of blade nodes with columns RNodes, AeroTwst DRNodes Chord and Nfoil
%.PrnElm           An array determining whether or not to print a given element


%These arrays are extracted from the FAST input file
%
% In:   FST_file    -   Name of FAST input file
%       hdrLines    -   Number of lines to skip at the top (optional)
%
% Knud A. Kragh, May 2011, NREL, Boulder
%
% Modified by Paul Fleming, JUNE 2011
% Modified by Bonnie Jonkman, February 2013 (to allow us to read the 
% platform file, too)
%%
if nargin < 2
    hdrLines = 0;
end

%----------------------Read FST main file----------------------------------
fid = fopen(FST_file,'r');

if fid == -1
    error(['FST file, ' FST_file ', could not be opened for reading. Check if the file exists or is locked.'])
end

%skip hdr
for hi = 1:hdrLines
    if nargin == 3
        fgetl(fid);
    else
        DataOut.HdrLines{hi,1} = fgetl(fid); %bjj: added field for storing header lines
    end
end

%PF: Commenting this out, not sure it's necessary
%DataOut.Sections=0;

%Loop through the file line by line, looking for value-label pairs
%Stop once we've reached the OutList which this function is the last
%occuring thing before the EOF
if nargin == 3
    
    count = max(length(DataOut.Label),length(DataOut.Val))+1;
else
    count = 1;
end


while true %loop until discovering Outlist or end of file, than break
    
    line = fgetl(fid);
    
    if isnumeric(line) % we reached the end of the file
        break
    end
    
        % Check to see if the value is Outlist
    if ~isempty(strfind(upper(line),upper('OutList'))) 
        [DataOut.OutList DataOut.OutListComments] = ParseFASTOutList(fid);
        break; %bjj: we could continue now if we wanted to assume OutList wasn't the end of the file...
    end      

        
    [value, label, isComment, descr, fieldType] = ParseFASTInputLine( line );    
    

    if ~isComment
        
        if strcmpi(value,'"HtFract"') %we've reached the distributed tower properties table (and we think it's a string value so it's in quotes)
            NTwInpSt = GetFastPar(DataOut,'NTwInpSt');        
            [DataOut.TowProp, DataOut.TowPropHdr] = ParseFASTNumTable(line, fid, NTwInpSt);
            continue; %let's continue reading the file
        elseif strcmpi(value,'"BlFract"') %we've reached the distributed blade properties table (and we think it's a string value so it's in quotes)
            NBlInpSt = GetFastPar(DataOut,'NBlInpSt');        
            [DataOut.BldProp, DataOut.BldPropHdr] = ParseFASTNumTable(line, fid, NBlInpSt);
            continue; %let's continue reading the file
        elseif strcmpi(value,'"GenSpd_TLU"') %we've reached the DLL torque-speed lookup table (and we think it's a string value so it's in quotes)
            DLL_NumTrq = GetFastPar(DataOut,'DLL_NumTrq');        
            [DataOut.DLLProp, DataOut.DLLPropHdr] = ParseFASTNumTable(line, fid, DLL_NumTrq);
            continue; %let's continue reading the file
        elseif strcmpi(label,'FoilNm') %note NO quotes because it's a label
            NumFoil = GetFastPar(DataOut,'NumFoil');
            [DataOut.FoilNm] = ParseFASTFileList( line, fid, NumFoil );
            continue; %let's continue reading the file  
        elseif strcmpi(value,'"RNodes"')
            BldNodes = GetFastPar(DataOut,'BldNodes');  
            [DataOut.BldNodes, DataOut.BldNodesHdr] = ParseFASTFmtTable( line, fid, BldNodes, false );
            continue;
        else                
            DataOut.Label{count,1} = label;
            DataOut.Val{count,1}   = value;
            count = count + 1;
        end
    end
    
end %end while

fclose(fid); %close file

return
end %end function
%%
function [OutList OutListComments] = ParseFASTOutList( fid )

    %Now loop and read in the OutList
    
    outCount = 0;
    while true
        line = fgetl(fid);
        if isempty(line) %Fortran allows blank lines in this list
            continue; 
        end
        [outVarC, position] = textscan(line,'%q',1); %we need to get the entire quoted line
        outVar  = outVarC{1}{1};    % this will not have quotes around it anymore...

        if isnumeric(line) %loop until we reach the word END or hit the end of the file
            break;
        else
            indx = strfind(upper(outVar),'END');
            if (~isempty(indx) && indx == 1) %we found "END" so that's the end of the file
                break;
            else
                outCount = outCount + 1;
                OutList{outCount,1} = ['"' outVar '"'];
                if position < length(line)
                  OutListComments{outCount,1} = line((position+1):end);
                else
                  OutListComments{outCount,1} = ' ';
                end
            end
        end
    end %end while   

    if outCount == 0
        disp( 'WARNING: no outputs found in OutList' );
        OutList = [];
        OutListComments = '';
    end
    
end %end function
%%
function [Table, Headers] = ParseFASTNumTable( line, fid, InpSt  )

    % read a numeric table from the FAST file
    
    % we've read the line of the table that includes the header 
    % let's parse it now, getting the number of columns as well:
    TmpHdr  = textscan(line,'%s');
    Headers = TmpHdr{1};
    nc = length(Headers);

    % read the units line:
    fgetl(fid); 
        
    % now initialize Table and read its values from the file:
    Table = zeros(InpSt, nc);   %this is the size table we'll read
    i = 0;                      % this the line of the table we're reading    
    while i < InpSt
        
        line = fgetl(fid);
        if isnumeric(line)      % we reached the end prematurely
            break
        end        

        i = i + 1;
        Table(i,:) = sscanf(line,'%f',nc);       

    end
    
end %end function
%%
function [Table, Headers] = ParseFASTFmtTable( line, fid, InpSt, unitsLine )

    % we've read the line of the table that includes the header 
    % let's parse it now, getting the number of columns as well:
    TmpHdr  = textscan(line,'%s');
    Headers = TmpHdr{1};
    nc = length(Headers);

    if nargin < 4 || unitsLine
        % read the units line:
        fgetl(fid); 
    end
        
    % now initialize Table and read its values from the file:
    Table = cell(InpSt,nc);   % this is the size table we'll read
    i = 0;                    % this the line of the table we're reading    
    while i < InpSt
        
        line = fgetl(fid);
        if isnumeric(line)      % we reached the end prematurely
            break
        end        

        i = i + 1;
        TmpValue  = textscan(line,'%s',nc); 
        for j=1:nc
            [testVal, cnt] = sscanf(TmpValue{1}{j},'%f',1);
            if cnt == 0
                Table{i,j}=TmpValue{1}{j};
            else
                Table{i,j}=testVal;
            end
        end
        %Table(i,:) = TmpValue{1};       

    end
    
end %end function

%%
function [fileList] = ParseFASTFileList( line, fid, nRows  )

    % we've read the line of the file that includes the first 
    % list of (airfoil) file names:
    fileList = cell(nRows,1);

    TmpValue  = textscan(line,'%s',1);
    fileList{1} = TmpValue{1}{1};

    for i=2:nRows
        line = fgetl(fid);
        if isnumeric(line)      % we reached the end prematurely
            break
        end
        
        TmpValue  = textscan(line,'%s',1);
        fileList{i} = TmpValue{1}{1};
    end
    
end %end function



