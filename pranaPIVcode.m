function pranaPIVcode(Data)
%% Set up a parallel job if needed
if str2double(Data.par)
    fprintf('\n--- Initializing Processor Cores for Parallel Job ----\n')
    poolopen=1;
    
    %Don't open more processors than there are image pairs
    if length(str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend)) < str2double(Data.parprocessors)
        Data.parprocessors=num2str(length(str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend)));
    end
    
    try
        matlabpool('open','local',Data.parprocessors);
    catch
        try
            matlabpool close
            matlabpool('open','local',Data.parprocessors);
        catch
            beep
            disp('Error Running Job in Parallel - Defaulting to Single Processor')
            poolopen=0;
            fprintf('\n-------------- Processing Dataset ------------------\n')
            pranaprocessing(Data)
            fprintf('---------------- Job Completed ---------------------\n')
        end
    end
    if poolopen
        I1=str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend);
        I2=I1+str2double(Data.imcstep); 
        if strcmp(Data.masktype,'dynamic')
            maskfend=str2double(Data.maskfstart)+str2double(Data.maskfstep)*length(str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend))-1;
            maskname=str2double(Data.maskfstart):str2double(Data.maskfstep):maskfend;
        else
            maskname=nan(1,length(I1));
        end
        
        if str2double(Data.method)==4
            fprintf('\n-------------- Processing Dataset ------------------\n')
            pranaprocessing(Data)
            fprintf('---------------- Job Completed ---------------------\n')
        else
            fprintf('\n--------------- Processing Dataset -------------------\n')
            spmd
                verstr=version('-release');
                if str2double(verstr(1:4))>=2010
                    I1dist=getLocalPart(codistributed(I1,codistributor('1d',2)));
                    I2dist=getLocalPart(codistributed(I2,codistributor('1d',2)));
                    masknamedist=getLocalPart(codistributed(maskname,codistributor('1d',2)));
                else
                    I1dist=localPart(codistributed(I1,codistributor('1d',2),'convert'));
                    I2dist=localPart(codistributed(I2,codistributor('1d',2),'convert'));
                    masknamedist=localPart(codistributed(maskname,codistributor('1d',2),'convert'));
                end
                
                if str2double(Data.method)==5
                    try
                        if labindex~=1
                            previous = labindex-1;
                        else
                            previous = numlabs;
                        end
                        if labindex~=numlabs
                            next = labindex+1;
                        else
                            next = 1;
                        end

                        I1extra_end=labSendReceive(previous,next,I1dist(1:str2double(Data.framestep)));
                        I2extra_end=labSendReceive(previous,next,I2dist(1:str2double(Data.framestep)));
                        masknameextra_end=labSendReceive(previous,next,masknamedist(1:str2double(Data.framestep)));

                        I1extra_beg=labSendReceive(next,previous,I1dist((end-str2double(Data.framestep)+1):end));
                        I2extra_beg=labSendReceive(next,previous,I2dist((end-str2double(Data.framestep)+1):end));
                        masknameextra_beg=labSendReceive(next,previous,masknamedist((end-str2double(Data.framestep)+1):end));

                        if labindex<numlabs
                            I1dist = [I1dist,I1extra_end];
                            I2dist = [I2dist,I2extra_end];
                            masknamedist = [masknamedist,masknameextra_end];
                        end
                        if 1<labindex
                            I1dist = [I1extra_beg,I1dist];
                            I2dist = [I2extra_beg,I2dist];
                            masknamedist = [masknameextra_beg,masknamedist];
                        end
                    catch
                        beep
                        disp('Error Running Multiframe Job in Parallel (Not Enough Image Pairs) - Defaulting to Single Processor')
                        matlabpool close
                        poolopen=0;
                        pranaprocessing(Data)
                    end

                end

                pranaprocessing(Data,I1dist,I2dist,masknamedist);
            end
            fprintf('----------------- Job Completed ----------------------\n')
        end
        if poolopen
            matlabpool close
        end
    end
else
    fprintf('\n-------------- Processing Dataset ------------------\n')
    pranaprocessing(Data)
    fprintf('---------------- Job Completed ---------------------\n')
end

function pranaprocessing(Data,I1,I2,maskname)
%% --- Read Formatted Parameters ---
%input/output directory
if ispc
    imbase=[Data.imdirec '\' Data.imbase];
    maskbase=[Data.maskdirec '\' Data.maskbase];
    pltdirec=[Data.outdirec '\'];
else
    imbase=[Data.imdirec '/' Data.imbase];
    maskbase=[Data.maskdirec '/' Data.maskbase];
    pltdirec=[Data.outdirec '/'];
end

if nargin<3
    I1 = str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend);
    I2 = I1+str2double(Data.imcstep);
end

%processing mask
if strcmp(Data.masktype,'none')
    mask = 1+0*double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I1(1))]));
    maskname=[];
elseif strcmp(Data.masktype,'static')
    mask = double(imread(Data.staticmaskname));
    mask = flipud(mask);
    maskname=[];
elseif strcmp(Data.masktype,'dynamic')
    if nargin<4
        maskfend=str2double(Data.maskfstart)+str2double(Data.maskfstep)*length(str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend))-1;
        maskname=str2double(Data.maskfstart):str2double(Data.maskfstep):maskfend;
    end
end

%method and passes
P=str2double(Data.passes);
Method={'Multipass','Multigrid','Deform','Ensemble','Multiframe'};
M=Method(str2double(Data.method));

%algorithm options
Velinterp=str2double(Data.velinterp);
Iminterp=str2double(Data.iminterp);
Nmax=str2double(Data.framestep);
ds=str2double(Data.PIVerror);

%physical parameters
Mag = str2double(Data.wrmag);
dt = str2double(Data.wrsep);
Freq = str2double(Data.wrsamp);

%initialization
Wres=zeros(P,2);
Wsize=zeros(P,2);
Gres=zeros(P,2);
Gbuf=zeros(P,2);
Corr=zeros(P,1);
D=zeros(P,1);
Zeromean=zeros(P,1);
Peaklocator=zeros(P,1);
Velsmoothswitch=zeros(P,1);
Velsmoothfilt=zeros(P,1);
Valswitch=zeros(P,1);
UODswitch=zeros(P,1);
Bootswitch=zeros(P,1);
Threshswitch=zeros(P,1);
Writeswitch=zeros(P,1);
Peakswitch=zeros(P,1);
UODwinsize=zeros(P,2,1);
UODthresh=zeros(P,1);
Bootper=zeros(P,1);
Bootiter=zeros(P,1);
Bootkmax=zeros(P,1);
Uthresh=zeros(P,2);
Vthresh=zeros(P,2);
extrapeaks=zeros(P,1);
PeakNum=zeros(P,1);
PeakMag=zeros(P,1);
PeakVel=zeros(P,1);
wbase=cell(0);

%read data info for each pass
for e=1:P
    
    %create structure for pass "e"
    eval(['A=Data.PIV' num2str(e) ';'])
    
    %store bulk window offset info
    if e==1
        BWO=[str2double(A.BWO(1:(strfind(A.BWO,',')-1))) str2double(A.BWO((strfind(A.BWO,',')+1):end))];
    end
    
    %window and grid resolution
    Wres(e,:)=[str2double(A.winres(1:(strfind(A.winres,',')-1))) str2double(A.winres((strfind(A.winres,',')+1):end))];
    Wsize(e,:)=[str2double(A.winsize(1:(strfind(A.winsize,',')-1))) str2double(A.winsize((strfind(A.winsize,',')+1):end))];
    Gres(e,:)=[str2double(A.gridres(1:(strfind(A.gridres,',')-1))) str2double(A.gridres((strfind(A.gridres,',')+1):end))];
    Gbuf(e,:)=[str2double(A.gridbuf(1:(strfind(A.gridbuf,',')-1))) str2double(A.gridbuf((strfind(A.gridbuf,',')+1):end))];
    Corr(e)=str2double(A.corr)-1;
    D(e)=str2double(A.RPCd);
    Zeromean(e)=str2double(A.zeromean);
    Peaklocator(e)=str2double(A.peaklocator);
    Velsmoothswitch(e)=str2double(A.velsmooth);
    Velsmoothfilt(e)=str2double(A.velsmoothfilt);
    
    %validation and thresholding
    Valswitch(e)=str2double(A.val);
    UODswitch(e)=str2double(A.uod);
    Bootswitch(e)=str2double(A.bootstrap);
    Threshswitch(e)=str2double(A.thresh);
    Writeswitch(e)=str2double(A.write);

    vpass=[0 strfind(A.uod_window,';') length(A.uod_window)+1];
    for q=1:(length(vpass)-1)
        B=A.uod_window((vpass(q)+1):(vpass(q+1)-1));
        UODwinsize(e,:,q)=[str2double(B(1:(strfind(B,',')-1))) str2double(B((strfind(B,',')+1):end))];
        UODthresh(e,q)=str2double(A.uod_thresh(1+2*(q-1)));
    end
    
    Bootper(e)=str2double(A.bootstrap_percentsampled);
    Bootiter(e)=str2double(A.bootstrap_iterations);
    Bootkmax(e)=str2double(A.bootstrap_passes);
    
    if str2double(A.thresh)==1
        Uthresh(e,:)=[str2double(A.valuthresh(1:(strfind(A.valuthresh,',')-1))) str2double(A.valuthresh((strfind(A.valuthresh,',')+1):end))];
        Vthresh(e,:)=[str2double(A.valvthresh(1:(strfind(A.valvthresh,',')-1))) str2double(A.valvthresh((strfind(A.valvthresh,',')+1):end))];
    else
        Uthresh(e,:)=[-inf,inf];
        Vthresh(e,:)=[-inf,inf];
    end
    
    extrapeaks(e)=str2double(A.valextrapeaks);

    %peak information
    Peakswitch(e)=str2double(A.savepeakinfo);
    PeakNum(e)=str2double(A.corrpeaknum);
    PeakMag(e)=str2double(A.savepeakmag);
    PeakVel(e)=str2double(A.savepeakvel);
    
    %output directory
    wbase(e,:)={A.outbase};
    
end


%% --- Evaluate Image Sequence ---
switch char(M)

    case {'Multipass','Multigrid','Deform'}
        
        for q=1:length(I1)                   
            tf=tic;
            frametitle=['Frame' sprintf(['%0.' Data.imzeros 'i'],I1(q)) ' and Frame' sprintf(['%0.' Data.imzeros 'i'],I2(q))];

            %load image pair and flip coordinates
            im1=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I1(q))]));
            im2=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I2(q))]));
            im1=flipud(im1);
            im2=flipud(im2);
            L=size(im1);
            
            %load dynamic mask and flip coordinates
            if strcmp(Data.masktype,'dynamic')
                mask = double(imread([maskbase sprintf(['%0.' Data.maskzeros 'i.' Data.maskext],maskname(q))]));
                mask = flipud(mask);
            end

            %initialize grid and evaluation matrix
            [XI,YI]=IMgrid(L,[0 0]);

            UI = BWO(1)*ones(size(XI));
            VI = BWO(2)*ones(size(YI));

            for e=1:P
                t1=tic;
                [X,Y]=IMgrid(L,Gres(e,:),Gbuf(e,:));
                S=size(X);X=X(:);Y=Y(:);
                
                if strcmp(M,'Multipass')
                    Ub=UI(:);
                    Vb=VI(:);
                else
                    Ub = reshape(downsample(downsample( UI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
                    Vb = reshape(downsample(downsample( VI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
                end
                Eval=reshape(downsample(downsample( mask(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
                Eval(Eval==0)=-1;
                Eval(Eval>0)=0;

                %correlate image pair
                if (e~=1) && strcmp(M,'Deform')         %then don't offset windows, images already deformed
                    if Corr(e)<2
                        [Xc,Yc,Uc,Vc,Cc]=PIVwindowed(im1d,im2d,Corr(e),Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),Peaklocator(e),Peakswitch(e) || (Valswitch(e) && extrapeaks(e)),X(Eval>=0),Y(Eval>=0));
                        if Peakswitch(e) || (Valswitch(e) && extrapeaks(e))
                            Uc = Uc + repmat(Ub(Eval>=0),[1 3]);   %reincorporate deformation as velocity for next pass
                            Vc = Vc + repmat(Vb(Eval>=0),[1 3]);
                        else
                            Uc = Uc + Ub(Eval>=0);   %reincorporate deformation as velocity for next pass
                            Vc = Vc + Vb(Eval>=0);
                        end
                    else
                        [Xc,Yc,Uc,Vc,Cc]=PIVphasecorr(im1d,im2d,Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),Peakswitch(e),X(Eval>=0),Y(Eval>=0));
                        Uc = Uc + Ub(Eval>=0);   %reincorporate deformation as velocity for next pass
                        Vc = Vc + Vb(Eval>=0);
                    end
                    
                else                                    %either first pass, or not deform
                    if Corr(e)<2
                        [Xc,Yc,Uc,Vc,Cc]=PIVwindowed(im1,im2,Corr(e),Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),Peaklocator(e),Peakswitch(e) || (Valswitch(e) && extrapeaks(e)),X(Eval>=0),Y(Eval>=0),Ub(Eval>=0),Vb(Eval>=0));
                    else
                        [Xc,Yc,Uc,Vc,Cc]=PIVphasecorr(im1,im2,Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),Peakswitch(e),X(Eval>=0),Y(Eval>=0),Ub(Eval>=0),Vb(Eval>=0));
                    end
                end
                
                if Corr(e)<2
                    if Peakswitch(e) || (Valswitch(e) && extrapeaks(e))
                        U=zeros(size(X,1),3);
                        V=zeros(size(X,1),3);
                        U(repmat(Eval>=0,[1 3]))=Uc;V(repmat(Eval>=0,[1 3]))=Vc;
                        C=zeros(size(X,1),3);
                        C(repmat(Eval>=0,[1 3]))=Cc;
                    else
                        U=zeros(size(X));V=zeros(size(X));C=[];
                        U(Eval>=0)=Uc;V(Eval>=0)=Vc;
                    end
                else
                    U=zeros(size(X));V=zeros(size(X));
                    U(Eval>=0)=Uc;V(Eval>=0)=Vc;
                    if Peakswitch(e)
                        C=zeros(size(X,1),3);
                        C(repmat(Eval>=0,[1 3]))=Cc;
                    else 
                        C=[];
                    end
                end
                
                corrtime(e)=toc(t1);

                %validation
                if Valswitch(e)
                    t1=tic;
                    
                    [Uval,Vval,Evalval,Cval]=VAL(X,Y,U,V,Eval,C,Threshswitch(e),UODswitch(e),Bootswitch(e),extrapeaks(e),...
                        Uthresh(e,:),Vthresh(e,:),UODwinsize(e,:,:),UODthresh(e,UODthresh(e,:)~=0)',Bootper(e),Bootiter(e),Bootkmax(e));
                    
                    valtime(e)=toc(t1);
                else
                    Uval=U(:,1);Vval=V(:,1);Evalval=Eval(:,1);
                    if ~isempty(C)
                        Cval=C(:,1);
                    else
                        Cval=[];
                    end
                end
                
                %write output
                if Writeswitch(e) 
                    t1=tic;
                        
                    if Peakswitch(e)
                        if PeakVel(e) && Corr(e)<2
                            U=[Uval,U(:,1:PeakNum(e))];
                            V=[Vval,V(:,1:PeakNum(e))];
                        else
                            U=Uval; V=Vval;
                        end
                        if PeakMag(e)
                            C=[Cval,C(:,1:PeakNum(e))];
                        else
                            C=Cval;
                        end
                    else
                        U=Uval; V=Vval; C=Cval;
                    end
                    Eval=Evalval;

                    %convert to physical units
                    Xval=X;Yval=Y;
                    X=X*Mag;Y=Y*Mag;
                    U=U*Mag/dt;V=V*Mag/dt;

                    %convert to matrix if necessary
                    if size(X,2)==1
                        [X,Y,U,V,Eval,C]=matrixform(X,Y,U,V,Eval,C);
                    end

                    %remove nans from data, replace with zeros
                    U(Eval<0)=0;V(Eval<0)=0;
                    
                    if str2double(Data.datout)
                        time=I1(q)/Freq;
                        write_dat_val_C([pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'i.dat' ],I1(q))],X,Y,U,V,Eval,C,e,time,frametitle);
                    end
                    
                    if str2double(Data.multiplematout)
                        save([pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'i.mat' ],I1(q))],'X','Y','U','V','Eval','C')
                    end
                    X=Xval;Y=Yval;
                    
                    savetime(e)=toc(t1);
                end
                U=Uval; V=Vval;
        
                if e~=P
                    %reshape from list of grid points to matrix
                    X=reshape(X,[S(1),S(2)]);
                    Y=reshape(Y,[S(1),S(2)]);
                    U=reshape(U(:,1),[S(1),S(2)]);
                    V=reshape(V(:,1),[S(1),S(2)]);
                    
                    if strcmp(M,'Multigrid') || strcmp(M,'Deform')
                        t1=tic;

                        %velocity smoothing
                        if Velsmoothswitch(e)==1
                            [U,V]=VELfilt(U,V,Velsmoothfilt(e));
                        end

                        %velocity interpolation
                        UI = VFinterp(X,Y,U,XI,YI,Velinterp);
                        VI = VFinterp(X,Y,V,XI,YI,Velinterp);

                        interptime(e)=toc(t1);
                        
                        if strcmp(M,'Deform')
                            t1=tic;
                            
                            %translate pixel locations
                            XD1 = XI+UI/2;
                            YD1 = YI+VI/2;
                            XD2 = XI-UI/2;
                            YD2 = YI-VI/2;

                            %preallocate deformed images
                            im1d = zeros(L);
                            im2d = zeros(L);

                            %cardinal function interpolation
                            if Iminterp==1
                                for i=1:L(1)
                                    for j=1:L(2)

                                        %image 1 interpolation
                                        nmin=max([1 (round(YD1(i,j))-3)]);
                                        nmax=min([L(1) (round(YD1(i,j))+3)]);
                                        mmin=max([1 (round(XD1(i,j))-3)]);
                                        mmax=min([L(2) (round(XD1(i,j))+3)]);
                                        for n=nmin:nmax
                                            for m=mmin:mmax
                                                wi = sin(pi*(m-XD1(i,j)))*sin(pi*(n-YD1(i,j)))/(pi^2*(m-XD1(i,j))*(n-YD1(i,j)));
                                                im1d(n,m)=im1d(n,m)+im1(i,j)*wi;
                                            end
                                        end

                                        %image 2 interpolation
                                        nmin=max([1 (round(YD2(i,j))-3)]);
                                        nmax=min([L(1) (round(YD2(i,j))+3)]);
                                        mmin=max([1 (round(XD2(i,j))-3)]);
                                        mmax=min([L(2) (round(XD2(i,j))+3)]);
                                        for n=nmin:nmax
                                            for m=mmin:mmax
                                                wi = sin(pi*(m-XD2(i,j)))*sin(pi*(n-YD2(i,j)))/(pi^2*(m-XD2(i,j))*(n-YD2(i,j)));
                                                im2d(n,m)=im2d(n,m)+im2(i,j)*wi;
                                            end
                                        end

                                    end
                                end

                            %cardinal function interpolation with Blackman filter
                            elseif Iminterp==2

                                for i=1:L(1)
                                    for j=1:L(2)

                                        %image 1 interpolation
                                        nmin=max([1 (round(YD1(i,j))-3)]);
                                        nmax=min([L(1) (round(YD1(i,j))+3)]);
                                        mmin=max([1 (round(XD1(i,j))-3)]);
                                        mmax=min([L(2) (round(XD1(i,j))+3)]);
                                        for n=nmin:nmax
                                            for m=mmin:mmax
                                                wi = sin(pi*(m-XD1(i,j)))*sin(pi*(n-YD1(i,j)))/(pi^2*(m-XD1(i,j))*(n-YD1(i,j)));
                                                bi = (0.42+0.5*cos(pi*(m-XD1(i,j))/3)+0.08*cos(2*pi*(m-XD1(i,j))/3))*(0.42+0.5*cos(pi*(n-YD1(i,j))/3)+0.08*cos(2*pi*(n-YD1(i,j))/3));
                                                im1d(n,m)=im1d(n,m)+im1(i,j)*wi*bi;
                                            end
                                        end

                                        %image 2 interpolation
                                        nmin=max([1 (round(YD2(i,j))-3)]);
                                        nmax=min([L(1) (round(YD2(i,j))+3)]);
                                        mmin=max([1 (round(XD2(i,j))-3)]);
                                        mmax=min([L(2) (round(XD2(i,j))+3)]);
                                        for n=nmin:nmax
                                            for m=mmin:mmax
                                                wi = sin(pi*(m-XD2(i,j)))*sin(pi*(n-YD2(i,j)))/(pi^2*(m-XD2(i,j))*(n-YD2(i,j)));
                                                bi = (0.42+0.5*cos(pi*(m-XD2(i,j))/3)+0.08*cos(2*pi*(m-XD2(i,j))/3))*(0.42+0.5*cos(pi*(n-YD2(i,j))/3)+0.08*cos(2*pi*(n-YD2(i,j))/3));
                                                im2d(n,m)=im2d(n,m)+im2(i,j)*wi*bi;
                                            end
                                        end

                                    end
                                end

                            end

                            %clip lower values of deformed images
                            im1d(im1d<0)=0; im1d(isnan(im1d))=0;
                            im2d(im2d<0)=0; im2d(isnan(im2d))=0;

                            %JJC: don't want to do this, should deform windows from start each time
                            % im1=im1d; im2=im2d;
                            
%                             keyboard
%                             figure(1),imagesc(im1),colormap(gray),axis image xy,xlabel('im1')
%                             figure(2),imagesc(im2),colormap(gray),axis image xy,xlabel('im2')
%                             figure(3),imagesc(im1d),colormap(gray),axis image xy,xlabel('im1d')
%                             figure(4),imagesc(im2d),colormap(gray),axis image xy,xlabel('im2d')
%                             pause
%                             imwrite(uint8(im1d),[pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'ia.png' ],I1(q))]);
%                             imwrite(uint8(im2d),[pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'ib.png' ],I1(q))]);

                            deformtime(e)=toc(t1);
                        end
                    else
                        UI=U;VI=V;
                    end
                end
            end

            eltime=toc(tf);
            %output text
            fprintf('\n----------------------------------------------------\n')
            fprintf(['Job: ',Data.batchname,'\n'])
            fprintf([frametitle ' Completed (' num2str(q) '/' num2str(length(I1)) ')\n'])
            fprintf('----------------------------------------------------\n')
            for e=1:P
                fprintf('correlation...                   %0.2i:%0.2i.%0.0f\n',floor(corrtime(e)/60),floor(rem(corrtime(e),60)),rem(corrtime(e),60)-floor(rem(corrtime(e),60)))
                if Valswitch(e)
                    fprintf('validation...                    %0.2i:%0.2i.%0.0f\n',floor(valtime(e)/60),floor(rem(valtime(e),60)),rem(valtime(e),60)-floor(rem(valtime(e),60)))
                end
                if Writeswitch(e)
                    fprintf('save time...                     %0.2i:%0.2i.%0.0f\n',floor(savetime(e)/60),floor(rem(savetime(e),60)),rem(savetime(e),60)-floor(rem(savetime(e),60)))
                end
                if strcmp(M,'Multigrid') || strcmp(M,'Deform')
                    if e~=P
                        fprintf('velocity interpolation...        %0.2i:%0.2i.%0.0f\n',floor(interptime(e)/60),floor(rem(interptime(e),60)),rem(interptime(e),60)-floor(rem(interptime(e),60)))
                        if strcmp(M,'Deform')
                            fprintf('image deformation...             %0.2i:%0.2i.%0.0f\n',floor(deformtime(e)/60),floor(rem(deformtime(e),60)),rem(deformtime(e),60)-floor(rem(deformtime(e),60)))
                        end
                    end
                end
            end
            fprintf('total frame time...              %0.2i:%0.2i.%0.0f\n',floor(eltime/60),floor(rem(eltime,60)),rem(eltime,60)-floor(rem(eltime,60)))
            frametime(q)=eltime;
            comptime=mean(frametime)*(length(I1)-q);
            fprintf('estimated job completion time... %0.2i:%0.2i:%0.2i\n\n',floor(comptime/3600),floor(rem(comptime,3600)/60),floor(rem(comptime,60)))
        end

    case 'Ensemble'
        
        %initialize grid and evaluation matrix
        im1=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I1(1))]));
        L=size(im1);
        [XI,YI]=IMgrid(L,[0 0]);
        UI = BWO(1)*ones(size(XI));
        VI = BWO(2)*ones(size(XI));
            
        for e=1:P
            tf=tic;

            frametitle=['Frame' sprintf(['%0.' Data.imzeros 'i'],I1(1)) ' to Frame' sprintf(['%0.' Data.imzeros 'i'],I2(end))];
            fprintf('\n----------------------------------------------------\n')
            fprintf(['Job: ',Data.batchname,'\n'])
            fprintf([frametitle ' (Pass ' num2str(e) '/' num2str(P) ')\n'])
            fprintf('----------------------------------------------------\n')
                
            
            [X,Y]=IMgrid(L,Gres(e,:),Gbuf(e,:));
            S=size(X);X=X(:);Y=Y(:);
            Ub = reshape(downsample(downsample( UI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
            Vb = reshape(downsample(downsample( VI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
            Eval=reshape(downsample(downsample( mask(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
            Eval(Eval==0)=-1;
            Eval(Eval>0)=0;
            
            if Peakswitch(e) || (Valswitch(e) && extrapeaks(e))
                U=zeros(size(X,1),3);
                V=zeros(size(X,1),3);
                C=zeros(size(X,1),3);
            else
                U=zeros(size(X));V=zeros(size(X));C=[];
            end
            
            if str2double(Data.par) && matlabpool('size')>1
                
                spmd
                    verstr=version('-release');
                    if str2double(verstr(1:4))>=2010
                        I1dist=getLocalPart(codistributed(I1,codistributor('1d',2)));
                        I2dist=getLocalPart(codistributed(I2,codistributor('1d',2)));
                    else
                        I1dist=localPart(codistributed(I1,codistributor('1d',2),'convert'));
                        I2dist=localPart(codistributed(I2,codistributor('1d',2),'convert'));
                    end
                    
                    for q=1:length(I1dist)
                        t1=tic;

                        %load image pair and flip coordinates
                        im1=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I1dist(q))]));
                        im2=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I2dist(q))]));
                        im1=flipud(im1);
                        im2=flipud(im2);
%                         L=size(im1);

                        %correlate image pair and average correlations
                        [Xc,Yc,CC]=PIVensemble(im1,im2,Corr(e),Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),X(Eval>=0),Y(Eval>=0),Ub(Eval>=0),Vb(Eval>=0));
                        if q==1
                            CCmdist=CC;
                        else
                            CCmdist=CCmdist+CC;
                        end
                        corrtime=toc(t1);
                        fprintf('correlation...                 %0.2i:%0.2i.%0.0f\n',floor(corrtime/60),floor(rem(corrtime,60)),rem(corrtime,60)-floor(rem(corrtime,60)))
                    end
                end
                CCm=zeros(size(CCmdist{1}));
                for i=1:length(CCmdist)
                    CCm=CCm+CCmdist{i}/length(I1);
                end
                
            else
                
                for q=1:length(I1)
                    t1=tic;

                    %load image pair and flip coordinates
                    im1=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I1(q))]));
                    im2=double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I2(q))]));
                    im1=flipud(im1);
                    im2=flipud(im2);
%                     L=size(im1);

                    %correlate image pair and average correlations
                    [Xc,Yc,CC]=PIVensemble(im1,im2,Corr(e),Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),X(Eval>=0),Y(Eval>=0),Ub(Eval>=0),Vb(Eval>=0));
                    if q==1
                        CCm=CC/length(I1);
                    else
                        CCm=CCm+CC/length(I1);
                    end
                    corrtime=toc(t1);
                    fprintf('correlation...                   %0.2i:%0.2i.%0.0f\n',floor(corrtime/60),floor(rem(corrtime,60)),rem(corrtime,60)-floor(rem(corrtime,60)))
                end
            end
                
            %evaluate subpixel displacement of averaged correlation
            Z=size(CCm);
            ZZ=ones(Z(1),Z(2));
            
            if Peakswitch(e) || (Valswitch(e) && extrapeaks(e))
                Uc=zeros(Z(3),3);
                Vc=zeros(Z(3),3);
                Cc=zeros(Z(3),3);
                Ub=repmat(Ub,[1 3]);
                Vb=repmat(Vb,[1 3]);
                Eval=repmat(Eval,[1 3]);
            else
                Uc=zeros(Z(3),1);Vc=zeros(Z(3),1);Cc=[];
            end
            for s=1:Z(3)
                [Uc(s,:),Vc(s,:),Ctemp]=subpixel(CCm(:,:,s),Z(2),Z(1),ZZ,Peaklocator(e),Peakswitch(e) || (Valswitch(e) && extrapeaks(e)));
                if ~isempty(Cc)
                    Cc(s,:)=Ctemp;
                end
            end

            U(Eval>=0)=Uc(:)+round(Ub(Eval>=0));
            V(Eval>=0)=Vc(:)+round(Vb(Eval>=0));
            if ~isempty(Cc)
                C(Eval>=0)=Cc(:);
            end
            
            %validation
            if Valswitch(e)
                t1=tic;

                [Uval,Vval,Evalval,Cval]=VAL(X,Y,U,V,Eval,C,Threshswitch(e),UODswitch(e),Bootswitch(e),extrapeaks(e),...
                    Uthresh(e,:),Vthresh(e,:),UODwinsize(e,:,:),UODthresh(e,UODthresh(e,:)~=0)',Bootper(e),Bootiter(e),Bootkmax(e));

                valtime=toc(t1);
                fprintf('validation...                    %0.2i:%0.2i.%0.0f\n',floor(valtime/60),floor(rem(valtime,60)),rem(valtime,60)-floor(rem(valtime,60)))

            else
                Uval=U(:,1);Vval=V(:,1);Evalval=Eval(:,1);
                if ~isempty(C)
                    Cval=C(:,1);
                else
                    Cval=[];
                end
            end
                
            %write output
            if Writeswitch(e) 
                t1=tic;

                if Peakswitch(e)
                    if PeakVel(e) && Corr(e)<2
                        U=[Uval,U(:,1:PeakNum(e))];
                        V=[Vval,V(:,1:PeakNum(e))];
                        Eval=[Evalval,Eval(:,1:PeakNum(e))];
                    else
                        U=Uval; V=Vval; Eval=Evalval;
                    end
                    if PeakMag(e)
                        C=[Cval,C(:,1:PeakNum(e))];
                    else
                        C=Cval;
                    end
                else
                    U=Uval; V=Vval; Eval=Evalval; C=Cval;
                end

                %convert to physical units
                Xval=X;Yval=Y;
                X=X*Mag;Y=Y*Mag;
                U=U*Mag/dt;V=V*Mag/dt;

                %convert to matrix if necessary
                if size(X,2)==1
                    [X,Y,U,V,Eval,C]=matrixform(X,Y,U,V,Eval,C);
                end

                %remove nans from data, replace with zeros
                U(Eval<0)=0;V(Eval<0)=0;

                if str2double(Data.datout)
                    write_dat_val_C([pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'i.dat' ],I1(1))],X,Y,U,V,Eval,C,e,0,frametitle);
                end
                if str2double(Data.multiplematout)
                    save([pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'i.mat' ],I1(1))],'X','Y','U','V','Eval','C')
                end
                X=Xval;Y=Yval;

                savetime=toc(t1);
                fprintf('save time...                     %0.2i:%0.2i.%0.0f\n',floor(savetime/60),floor(rem(savetime,60)),rem(savetime,60)-floor(rem(savetime,60)))
            end
            U=Uval; V=Vval;
        
            if e~=P
                t1=tic;
                
                %reshape from list of grid points to matrix
                X=reshape(X,[S(1),S(2)]);
                Y=reshape(Y,[S(1),S(2)]);
                U=reshape(U(:,1),[S(1),S(2)]);
                V=reshape(V(:,1),[S(1),S(2)]);

                %velocity smoothing
                if Velsmoothswitch(e)==1
                    [U,V]=VELfilt(U,V,Velsmoothfilt(e));
                end

                %velocity interpolation
                UI = VFinterp(X,Y,U,XI,YI,Velinterp);
                VI = VFinterp(X,Y,V,XI,YI,Velinterp);

                interptime=toc(t1);
                fprintf('velocity interpolation...        %0.2i:%0.2i.%0.0f\n',floor(interptime/60),floor(rem(interptime,60)),rem(interptime,60)-floor(rem(interptime,60)))
            end
            
            eltime=toc(tf);
            %output text
            fprintf('total pass time...               %0.2i:%0.2i.%0.0f\n',floor(eltime/60),floor(rem(eltime,60)),rem(eltime,60)-floor(rem(eltime,60)))
            frametime(e)=eltime;
            comptime=mean(frametime)*(P-e);
            fprintf('estimated job completion time... %0.2i:%0.2i:%0.2i\n',floor(comptime/3600),floor(rem(comptime,3600)/60),floor(rem(comptime,60)))
        end
        
    case 'Multiframe'
        
        I1_full=str2double(Data.imfstart):str2double(Data.imfstep):str2double(Data.imfend);
        time_full=str2double(Data.imfstart):(str2double(Data.imfend)+str2double(Data.imcstep));
        
        %single-pulsed
        if round(1/Freq*10^6)==round(dt)
            time_full(2,:)=time_full(1,:);
        else
            %double-pulsed
            for n=3:2:length(time_full)
                time_full(2,n)=floor(n/2)/Freq/dt;
                time_full(2,n-1)=floor((n-2)/2)/Freq/dt+1;
            end
        end

        if I1(1)==I1_full(1)
            qstart=1;
        else
            qstart=Nmax+1;
        end
        if I1(end)==I1_full(end)
            qend=length(I1);
        else
            qend=length(I1)-Nmax;
        end
        frametime=nan(length(qstart:qend),1);
        
        for q=qstart:qend
            tf=tic;
            frametitle=['Frame' sprintf(['%0.' Data.imzeros 'i'],I1(q)) ' and Frame' sprintf(['%0.' Data.imzeros 'i'],I2(q))];
            
            %load dynamic mask and flip coordinates
            if strcmp(Data.masktype,'dynamic')
                mask = double(imread([maskbase sprintf(['%0.' Data.maskzeros 'i.' Data.maskext],maskname(q))]));
                mask = flipud(mask);
            end
            
            %load image pairs, compute delta-t, and flip coordinates
            if q-Nmax<1 && q+Nmax>length(I1)
                N=min([q,length(I1)-q+1]);
            elseif q-Nmax<1
                N=q;
            elseif q+Nmax>length(I1)
                N=length(I1)-q+1;
            else
                N=Nmax+1;
            end
            im1=zeros(size(mask,1),size(mask,2),N); im2=im1;
            for n=1:N
                im1(:,:,n)=flipud(double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I1(q)-(n-1))])));
                im2(:,:,n)=flipud(double(imread([imbase sprintf(['%0.' Data.imzeros 'i.' Data.imext],I2(q)+(n-1))])));
                if Zeromean(e)==1
                    im1(:,:,n)=im1(:,:,n)-mean(mean(im1(:,:,n)));
                    im2(:,:,n)=im2(:,:,n)-mean(mean(im2(:,:,n)));
                end
                
                imind1= time_full(1,:)==I1(q)-(n-1);
                imind2= time_full(1,:)==I2(q)+(n-1);
                Dt(n)=time_full(2,imind2)-time_full(2,imind1);
            end
            L=size(im1);

            %initialize grid and evaluation matrix
            [XI,YI]=IMgrid(L,[0 0]);

            UI = zeros(size(XI));
            VI = zeros(size(YI));

            for e=1:P
                t1=tic;
                [X,Y]=IMgrid(L,Gres(e,:),Gbuf(e,:));
                S=size(X);X=X(:);Y=Y(:);
                Uc=[];Vc=[];Cc=[];

                if Corr(e)<2
                    U=zeros(size(X,1),3,N);
                    V=zeros(size(X,1),3,N);
                    C=zeros(size(X,1),3,N);
                    Eval=repmat(reshape(downsample(downsample( mask(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1),[1 3]);
                    Eval(Eval==0)=-1;
                    Eval(Eval>0)=0;
                    
                    for t=1:N
                        Ub = reshape(downsample(downsample( UI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1).*Dt(t);
                        Vb = reshape(downsample(downsample( VI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1).*Dt(t);
                        %correlate image pair
                        [Xc,Yc,Uc(:,:,t),Vc(:,:,t),Cc(:,:,t)]=PIVwindowed(im1(:,:,t),im2(:,:,t),Corr(e),Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),Peaklocator(e),1,X(Eval(:,1)>=0),Y(Eval(:,1)>=0),Ub(Eval(:,1)>=0),Vb(Eval(:,1)>=0));
                    end
                    U(repmat(Eval>=0,[1 1 N]))=Uc;
                    V(repmat(Eval>=0,[1 1 N]))=Vc;
                    C(repmat(Eval>=0,[1 1 N]))=Cc;

                    velmag=sqrt(U(:,1,:).^2+V(:,1,:).^2);
                    Qp=C(:,1,:)./C(:,2,:).*(1-ds./velmag);
                    [Qmax,t_opt]=max(Qp,[],3);
                    for i=1:size(U,1)
                        Uval(i,:)=U(i,:,t_opt(i));
                        Vval(i,:)=V(i,:,t_opt(i));
                        Cval(i,:)=C(i,:,t_opt(i));
                    end

                    try
                        U=Uval./repmat(Dt(t_opt)',[1 3]);
                        V=Vval./repmat(Dt(t_opt)',[1 3]);
                    catch
                        U=Uval./repmat(Dt(t_opt),[1 3]);
                        V=Vval./repmat(Dt(t_opt),[1 3]);
                    end
                    
                else
                    U=zeros(length(X),1);
                    V=zeros(length(X),1);
                    Eval=reshape(downsample(downsample( mask(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
                    Eval(Eval==0)=-1;
                    Eval(Eval>0)=0;
                    
                    Ub = reshape(downsample(downsample( UI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
                    Vb = reshape(downsample(downsample( VI(Y(1):Y(end),X(1):X(end)),Gres(e,2))',Gres(e,1))',length(X),1);
                    [Xc,Yc,Uc,Vc,Cc,t_optc]=PIVphasecorr(im1,im2,Wsize(e,:),Wres(e,:),0,D(e),Zeromean(e),Peakswitch(e),X(Eval>=0),Y(Eval>=0),Ub(Eval>=0),Vb(Eval>=0),Dt);
                    if Peakswitch(e)
                        C=zeros(length(X),3);
                        C(repmat(Eval,[1 3])>=0)=Cc;
                        t_opt=zeros(size(X));
                        t_opt(Eval>=0)=t_optc;
                    else
                        C=[];t_opt=[];
                    end
                    U(Eval>=0)=Uc;V(Eval>=0)=Vc;
                end
                
                corrtime(e)=toc(t1);
                
                %validation
                if Valswitch(e)
                    t1=tic;
                    
                    [Uval,Vval,Evalval,Cval]=VAL(X,Y,U,V,Eval,C,Threshswitch(e),UODswitch(e),Bootswitch(e),extrapeaks(e),...
                        Uthresh(e,:),Vthresh(e,:),UODwinsize(e,:,:),UODthresh(e,UODthresh(e,:)~=0)',Bootper(e),Bootiter(e),Bootkmax(e));
                    
                    valtime(e)=toc(t1);
                else
                    Uval=U(:,1);Vval=V(:,1);Evalval=Eval(:,1);
                    if ~isempty(C)
                        Cval=C(:,1);
                    else
                        Cval=[];
                    end
                end

                %write output
                if Writeswitch(e) 
                    t1=tic;
                    if Peakswitch(e)                    
                        if PeakVel(e) && Corr(e)<2
                            U=[Uval(:,1),U(:,1:PeakNum(e))];
                            V=[Vval(:,1),V(:,1:PeakNum(e))];
                            Eval=[Evalval(:,1),Eval(:,1:PeakNum(e))];
                        else
                            U=Uval(:,1); V=Vval(:,1);Eval=Evalval(:,1);
                        end
                        if PeakMag(e)
                            C=[Cval(:,1),C(:,1:PeakNum(e))];
                        else
                            C=[];
                        end
                    else
                        t_opt=[];
                    end
                    %convert to physical units
                    Xval=X;Yval=Y;
                    X=X*Mag;Y=Y*Mag;
                    U=U*Mag./dt;V=V*Mag./dt;

                    %convert to matrix if necessary
                    if size(X,2)==1
                        [X,Y,U,V,Eval,C]=matrixform(X,Y,U,V,Eval,C);
                        if Peakswitch(e)
                            t_opt=reshape(t_opt,size(X,1),size(X,2));
                        end
                    end

                    %remove nans from data, replace with zeros
                    U(Eval<0)=0;V(Eval<0)=0;
                    
                    if str2double(Data.datout)
%                         q_full=find(I1_full==I1(q),1,'first');
%                         time=(q_full-1)/Freq;
                        time=I1(q)/Freq;
                        write_dat_val_C([pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'i.dat' ],I1(q))],X,Y,U,V,Eval,C,e,time,frametitle,t_opt);
                    end
                    if str2double(Data.multiplematout)
                        save([pltdirec char(wbase(e,:)) sprintf(['%0.' Data.imzeros 'i.mat' ],I1(q))],'X','Y','U','V','Eval','C','t_opt')
                    end
                    X=Xval;Y=Yval;
                    
                    savetime(e)=toc(t1);
                end
                U=Uval; V=Vval;
                
                if e~=P
                    %reshape from list of grid points to matrix
                    X=reshape(X,[S(1),S(2)]);
                    Y=reshape(Y,[S(1),S(2)]);
                    U=reshape(U(:,1),[S(1),S(2)]);
                    V=reshape(V(:,1),[S(1),S(2)]);

                    t1=tic;

                    %velocity smoothing
                    if Velsmoothswitch(e)==1
                        [U,V]=VELfilt(U,V,Velsmoothfilt(e));
                    end
                    
                    %velocity interpolation
                    UI = VFinterp(X,Y,U,XI,YI,Velinterp);
                    VI = VFinterp(X,Y,V,XI,YI,Velinterp);

                    interptime(e)=toc(t1);
                end
                Uval=[];Vval=[];Cval=[];
            end

            eltime=toc(tf);
            %output text
            fprintf('\n----------------------------------------------------\n')
            fprintf(['Job: ',Data.batchname,'\n'])
            fprintf([frametitle ' Completed (' num2str(q+1-qstart) '/' num2str(length(qstart:qend)) ')\n'])
            fprintf('----------------------------------------------------\n')
            for e=1:P
                fprintf('correlation...                   %0.2i:%0.2i.%0.0f\n',floor(corrtime(e)/60),floor(rem(corrtime(e),60)),rem(corrtime(e),60)-floor(rem(corrtime(e),60)))
                if Valswitch(e)
                    fprintf('validation...                    %0.2i:%0.2i.%0.0f\n',floor(valtime(e)/60),floor(rem(valtime(e),60)),rem(valtime(e),60)-floor(rem(valtime(e),60)))
                end
                if Writeswitch(e)
                    fprintf('save time...                     %0.2i:%0.2i.%0.0f\n',floor(savetime(e)/60),floor(rem(savetime(e),60)),rem(savetime(e),60)-floor(rem(savetime(e),60)))
                end
                if e~=P
                    fprintf('velocity interpolation...        %0.2i:%0.2i.%0.0f\n',floor(interptime(e)/60),floor(rem(interptime(e),60)),rem(interptime(e),60)-floor(rem(interptime(e),60)))
                end
            end
            fprintf('total frame time...              %0.2i:%0.2i.%0.0f\n',floor(eltime/60),floor(rem(eltime,60)),rem(eltime,60)-floor(rem(eltime,60)))
            frametime(q+1-qstart)=eltime;
            comptime=nanmean(frametime)*(length(qstart:qend)-(q+1-qstart));
            fprintf('estimated job completion time... %0.2i:%0.2i:%0.2i\n\n',floor(comptime/3600),floor(rem(comptime,3600)/60),floor(rem(comptime,60)))
        end
end

%signal job complete
beep,pause(0.2),beep

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%                           END MAIN FUNCTION                             %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [X,Y,U,V,C]=PIVwindowed(im1,im2,corr,window,res,zpad,D,Zeromean,Peaklocator,Peakswitch,X,Y,Uin,Vin)
% --- DPIV Correlation ---

%convert input parameters
im1=double(im1);
im2=double(im2);
L=size(im1);

%convert to gridpoint list
X=X(:);
Y=Y(:);

%correlation and window mask types
ctype    = {'SCC','RPC'};
tcorr = char(ctype(corr+1)); 

%preallocate velocity fields and grid format
Nx = window(1);
Ny = window(2);
if nargin <=13
    Uin = zeros(length(X),1);
    Vin = zeros(length(X),1);
end

if Peakswitch
    Uin=repmat(Uin(:,1),[1 3]);
    Vin=repmat(Vin(:,1),[1 3]);
    U = zeros(length(X),3);
    V = zeros(length(X),3);
    C = zeros(length(X),3);
else
    U = zeros(length(X),1);
    V = zeros(length(X),1);
    C = [];
end

%sets up extended domain size
if zpad~=0
    Sy=2*Ny;
    Sx=2*Nx;
else
    Sy=Ny;
    Sx=Nx;
end

%window masking filter
sfilt = windowmask([Nx Ny],[res(1) res(2)]);

%correlation plane normalization function (always off)
cnorm = ones(Ny,Nx);

%RPC spectral energy filter
spectral = fftshift(energyfilt(Sx,Sy,D,0));

%fftshift indicies
fftindy = [Sy/2+1:Sy 1:Sy/2];
fftindx = [Sx/2+1:Sx 1:Sx/2];

switch upper(tcorr)

    %Standard Cross Correlation
    case 'SCC'

        for n=1:length(X)

            %apply the second order discrete window offset
            x1 = X(n) - floor(round(Uin(n))/2);
            x2 = X(n) +  ceil(round(Uin(n))/2);

            y1 = Y(n) - floor(round(Vin(n))/2);
            y2 = Y(n) +  ceil(round(Vin(n))/2);

            xmin1 = x1-Nx/2+1;
            xmax1 = x1+Nx/2;
            xmin2 = x2-Nx/2+1;
            xmax2 = x2+Nx/2;
            ymin1 = y1-Ny/2+1;
            ymax1 = y1+Ny/2;
            ymin2 = y2-Ny/2+1;
            ymax2 = y2+Ny/2;
                
            %find the image windows
            zone1 = im1( max([1 ymin1]):min([L(1) ymax1]),max([1 xmin1]):min([L(2) xmax1]));
            zone2 = im2( max([1 ymin2]):min([L(1) ymax2]),max([1 xmin2]):min([L(2) xmax2]));
            if size(zone1,1)~=Ny || size(zone1,2)~=Nx
                w1 = zeros(Ny,Nx);
                w1( 1+max([0 1-ymin1]):Ny-max([0 ymax1-L(1)]),1+max([0 1-xmin1]):Nx-max([0 xmax1-L(2)]) ) = zone1;
                zone1 = w1;
            end
            if size(zone2,1)~=Ny || size(zone2,2)~=Nx
                w2 = zeros(Ny,Nx);
                w2( 1+max([0 1-ymin2]):Ny-max([0 ymax2-L(1)]),1+max([0 1-xmin2]):Nx-max([0 xmax2-L(2)]) ) = zone2;
                zone2 = w2;
            end
            
            if Zeromean==1
                zone1=zone1-mean(mean(zone1));
                zone2=zone2-mean(mean(zone2));
            end

            %apply the image spatial filter
            region1 = (zone1).*sfilt;
            region2 = (zone2).*sfilt;

            %FFTs and Cross-Correlation
            f1   = fftn(region1,[Sy Sx]);
            f2   = fftn(region2,[Sy Sx]);
            P21  = f2.*conj(f1);

            %Standard Fourier Based Cross-Correlation
            G = ifftn(P21,'symmetric');
            G = G(fftindy,fftindx);
            G = abs(G);
            
            %subpixel estimation
            [U(n,:),V(n,:),Ctemp]=subpixel(G,Nx,Ny,cnorm,Peaklocator,Peakswitch);
%             winmean=mean(mean(region1))*mean(mean(region2));
%             [U(n,:),V(n,:),Ctemp]=subpixel(G,Nx,Ny,cnorm,Peaklocator,Peakswitch,winmean);
            if Peakswitch
                C(n,:)=Ctemp;
            end
        end

    %Robust Phase Correlation
    case 'RPC'
        
        for n=1:length(X)

            %apply the second order discrete window offset
            x1 = X(n) - floor(round(Uin(n))/2);
            x2 = X(n) +  ceil(round(Uin(n))/2);

            y1 = Y(n) - floor(round(Vin(n))/2);
            y2 = Y(n) +  ceil(round(Vin(n))/2);

            xmin1 = x1-Nx/2+1;
            xmax1 = x1+Nx/2;
            xmin2 = x2-Nx/2+1;
            xmax2 = x2+Nx/2;
            ymin1 = y1-Ny/2+1;
            ymax1 = y1+Ny/2;
            ymin2 = y2-Ny/2+1;
            ymax2 = y2+Ny/2;

            %find the image windows
            zone1 = im1( max([1 ymin1]):min([L(1) ymax1]),max([1 xmin1]):min([L(2) xmax1]));
            zone2 = im2( max([1 ymin2]):min([L(1) ymax2]),max([1 xmin2]):min([L(2) xmax2]));
            if size(zone1,1)~=Ny || size(zone1,2)~=Nx
                w1 = zeros(Ny,Nx);
                w1( 1+max([0 1-ymin1]):Ny-max([0 ymax1-L(1)]),1+max([0 1-xmin1]):Nx-max([0 xmax1-L(2)]) ) = zone1;
                zone1 = w1;
            end
            if size(zone2,1)~=Ny || size(zone2,2)~=Nx
                w2 = zeros(Ny,Nx);
                w2( 1+max([0 1-ymin2]):Ny-max([0 ymax2-L(1)]),1+max([0 1-xmin2]):Nx-max([0 xmax2-L(2)]) ) = zone2;
                zone2 = w2;
            end
            
            if Zeromean==1
                zone1=zone1-mean(mean(zone1));
                zone2=zone2-mean(mean(zone2));
            end

            %apply the image spatial filter
            region1 = (zone1).*sfilt;
            region2 = (zone2).*sfilt;

            %FFTs and Cross-Correlation
            f1   = fftn(region1,[Sy Sx]);
            f2   = fftn(region2,[Sy Sx]);
            P21  = f2.*conj(f1);

            %Phase Correlation
            W = ones(Sy,Sx);
            Wden = sqrt(P21.*conj(P21));
            W(P21~=0) = Wden(P21~=0);
            R = P21./W;

            %Robust Phase Correlation with spectral energy filter
            G = ifftn(R.*spectral,'symmetric');
            G = G(fftindy,fftindx);
            G = abs(G);

            %subpixel estimation
            [U(n,:),V(n,:),Ctemp]=subpixel(G,Nx,Ny,cnorm,Peaklocator,Peakswitch);
%             winmean=mean(mean(region1))*mean(mean(region2));
%             [U(n,:),V(n,:),Ctemp]=subpixel(G,Nx,Ny,cnorm,Peaklocator,Peakswitch,winmean);
            if Peakswitch
                C(n,:)=Ctemp;
            end
        end
end

%add DWO to estimation
U = round(Uin)+U;
V = round(Vin)+V;

function [X,Y,CC]=PIVensemble(im1,im2,corr,window,res,zpad,D,Zeromean,X,Y,Uin,Vin)
% --- DPIV Ensemble Correlation ---

%convert input parameters
im1=double(im1);
im2=double(im2);
L = size(im1);

%convert to gridpoint list
X=X(:);
Y=Y(:);

%correlation and window mask types
ctype    = {'SCC','RPC'};
tcorr = char(ctype(corr+1)); 

%preallocate velocity fields and grid format
Nx = window(1);
Ny = window(2);
if nargin <=11
    Uin = zeros(length(X),1);
    Vin = zeros(length(X),1);
end
Uin = Uin(:);
Vin = Vin(:);

%sets up extended domain size
if zpad~=0
    Sy=2*Ny;
    Sx=2*Nx;
else
    Sy=Ny;
    Sx=Nx;
end

%window masking filter
sfilt = windowmask([Nx Ny],[res(1) res(2)]);

%RPC spectral energy filter
spectral = fftshift(energyfilt(Sx,Sy,D,0));

%fftshift indicies
fftindy = [Sy/2+1:Sy 1:Sy/2];
fftindx = [Sx/2+1:Sx 1:Sx/2];

%initialize correlation tensor
CC = zeros(Sy,Sx,length(X));

switch upper(tcorr)

    %Standard Cross Correlation
    case 'SCC'

        for n=1:length(X)

            %apply the second order discrete window offset
            x1 = X(n) - floor(round(Uin(n))/2);
            x2 = X(n) +  ceil(round(Uin(n))/2);

            y1 = Y(n) - floor(round(Vin(n))/2);
            y2 = Y(n) +  ceil(round(Vin(n))/2);

            xmin1 = x1-Nx/2+1;
            xmax1 = x1+Nx/2;
            xmin2 = x2-Nx/2+1;
            xmax2 = x2+Nx/2;
            ymin1 = y1-Ny/2+1;
            ymax1 = y1+Ny/2;
            ymin2 = y2-Ny/2+1;
            ymax2 = y2+Ny/2;

            %find the image windows
            zone1 = im1( max([1 ymin1]):min([L(1) ymax1]),max([1 xmin1]):min([L(2) xmax1]) );
            zone2 = im2( max([1 ymin2]):min([L(1) ymax2]),max([1 xmin2]):min([L(2) xmax2]) );
            if size(zone1,1)~=Ny || size(zone1,2)~=Nx
                w1 = zeros(Ny,Nx);
                w1( 1+max([0 1-ymin1]):Ny-max([0 ymax1-L(1)]),1+max([0 1-xmin1]):Nx-max([0 xmax1-L(2)]) ) = zone1;
                zone1 = w1;
            end
            if size(zone2,1)~=Ny || size(zone2,2)~=Nx
                w2 = zeros(Ny,Nx);
                w2( 1+max([0 1-ymin2]):Ny-max([0 ymax2-L(1)]),1+max([0 1-xmin2]):Nx-max([0 xmax2-L(2)]) ) = zone2;
                zone2 = w2;
            end
            
            if Zeromean==1
                zone1=zone1-mean(mean(zone1));
                zone2=zone2-mean(mean(zone2));
            end
            
            %apply the image spatial filter
            region1 = (zone1).*sfilt;
            region2 = (zone2).*sfilt;

            %FFTs and Cross-Correlation
            f1   = fftn(region1-mean(region1(:)),[Sy Sx]);
            f2   = fftn(region2-mean(region2(:)),[Sy Sx]);
            P21  = f2.*conj(f1);

            %Standard Fourier Based Cross-Correlation
            G = ifftn(P21,'symmetric');
            G = G(fftindy,fftindx);
            G = abs(G);
            G = G/std(region1(:))/std(region2(:))/length(region1(:));
            
            %store correlation matrix
            CC(:,:,n) = G;

        end

    %Robust Phase Correlation
    case 'RPC'
        
        for n=1:length(X)

            %apply the second order discrete window offset
            x1 = X(n) - floor(round(Uin(n))/2);
            x2 = X(n) +  ceil(round(Uin(n))/2);

            y1 = Y(n) - floor(round(Vin(n))/2);
            y2 = Y(n) +  ceil(round(Vin(n))/2);

            xmin1 = x1-Nx/2+1;
            xmax1 = x1+Nx/2;
            xmin2 = x2-Nx/2+1;
            xmax2 = x2+Nx/2;
            ymin1 = y1-Ny/2+1;
            ymax1 = y1+Ny/2;
            ymin2 = y2-Ny/2+1;
            ymax2 = y2+Ny/2;

            %find the image windows
            zone1 = im1( max([1 ymin1]):min([L(1) ymax1]),max([1 xmin1]):min([L(2) xmax1]) );
            zone2 = im2( max([1 ymin2]):min([L(1) ymax2]),max([1 xmin2]):min([L(2) xmax2]) );
            if size(zone1,1)~=Ny || size(zone1,2)~=Nx
                w1 = zeros(Ny,Nx);
                w1( 1+max([0 1-ymin1]):Ny-max([0 ymax1-L(1)]),1+max([0 1-xmin1]):Nx-max([0 xmax1-L(2)]) ) = zone1;
                zone1 = w1;
            end
            if size(zone2,1)~=Ny || size(zone2,2)~=Nx
                w2 = zeros(Ny,Nx);
                w2( 1+max([0 1-ymin2]):Ny-max([0 ymax2-L(1)]),1+max([0 1-xmin2]):Nx-max([0 xmax2-L(2)]) ) = zone2;
                zone2 = w2;
            end
            
            if Zeromean==1
                zone1=zone1-mean(mean(zone1));
                zone2=zone2-mean(mean(zone2));
            end

            %apply the image spatial filter
            region1 = zone1.*sfilt;
            region2 = zone2.*sfilt;

            %FFTs and Cross-Correlation
            f1   = fftn(region1,[Sy Sx]);
            f2   = fftn(region2,[Sy Sx]);
            P21  = f2.*conj(f1);

            %Phase Correlation
            W = ones(Sy,Sx);
            Wden = sqrt(P21.*conj(P21));
            W(P21~=0) = Wden(P21~=0);
            R = P21./W;

            %Robust Phase Correlation with spectral energy filter
            G = ifftn(R.*spectral,'symmetric');
            G = G(fftindy,fftindx);
            G = abs(G);
            
            %store correlation matrix
            CC(:,:,n) = G;

        end
end

function [X,Y,U,V,C,t_opt]=PIVphasecorr(im1,im2,window,res,zpad,D,Zeromean,Peakswitch,X,Y,Uin,Vin,dt)
% --- DPIV Correlation ---

%convert input parameters
im1=double(im1);
im2=double(im2);
L=size(im1);

if nargin<13
    dt=1;
end

%convert to gridpoint list
X=X(:);
Y=Y(:);

%preallocate velocity fields and grid format
Nx = window(1);
Ny = window(2);
if nargin <=11 || isempty(Uin) || isempty(Vin)
    Uin = zeros(length(X),1);
    Vin = zeros(length(X),1);
end

U = zeros(length(X),1);
V = zeros(length(X),1);
C = [];
t_opt=zeros(length(X),1);

%RPC Cutoff filter
wt = energyfilt(Nx,Ny,D,0);
wt=wt(Nx/2+1,:);
% cutoff=2/pi/D;
% cutoff=exp(-1);
cutoff=0;
wt(wt<cutoff)=0;

%sets up extended domain size
if zpad~=0
    Sy=2*Ny;
    Sx=2*Nx;
else
    Sy=Ny;
    Sx=Nx;
end

for i=1:size(im1,3)
    if sum(Uin)==0 || sum(Vin)==0
        DT=dt(i);
    else
        DT=1;
    end
    lsqX{i}=(0:Sx-1).*DT-Sx/2*DT;
    lsqY{i}=(0:Sy-1).*DT-Sy/2*DT;
end

%window masking filter
sfilt = windowmask([Nx Ny],[res(1) res(2)]);

%fftshift indicies
fftindy = [Sy/2+1:Sy 1:Sy/2];
fftindx = [Sx/2+1:Sx 1:Sx/2];

for n=1:length(X)
    um_cum=[];vm_cum=[];wt_cum=[];lsqX_cum=[];lsqY_cum=[];
    for t=1:size(im1,3)     
        %apply the second order discrete window offset
        x1 = X(n) - floor(round(Uin(n)*dt(t))/2);
        x2 = X(n) +  ceil(round(Uin(n)*dt(t))/2);

        y1 = Y(n) - floor(round(Vin(n)*dt(t))/2);
        y2 = Y(n) +  ceil(round(Vin(n)*dt(t))/2);

        xmin1 = x1-Nx/2+1;
        xmax1 = x1+Nx/2;
        xmin2 = x2-Nx/2+1;
        xmax2 = x2+Nx/2;
        ymin1 = y1-Ny/2+1;
        ymax1 = y1+Ny/2;
        ymin2 = y2-Ny/2+1;
        ymax2 = y2+Ny/2;
    
        %find the image windows
        zone1 = im1( max([1 ymin1]):min([L(1) ymax1]),max([1 xmin1]):min([L(2) xmax1]),t);
        zone2 = im2( max([1 ymin2]):min([L(1) ymax2]),max([1 xmin2]):min([L(2) xmax2]),t);
        if size(zone1,1)~=Ny || size(zone1,2)~=Nx
            w1 = zeros(Ny,Nx);
            w1( 1+max([0 1-ymin1]):Ny-max([0 ymax1-L(1)]),1+max([0 1-xmin1]):Nx-max([0 xmax1-L(2)]) ) = zone1;
            zone1 = w1;
        end
        if size(zone2,1)~=Ny || size(zone2,2)~=Nx
            w2 = zeros(Ny,Nx);
            w2( 1+max([0 1-ymin2]):Ny-max([0 ymax2-L(1)]),1+max([0 1-xmin2]):Nx-max([0 xmax2-L(2)]) ) = zone2;
            zone2 = w2;
        end
        
        if Zeromean==1
            zone1=zone1-mean(mean(zone1));
            zone2=zone2-mean(mean(zone2));
        end

        %apply the image spatial filter
        region1 = (zone1).*sfilt;
        region2 = (zone2).*sfilt;

        %FFTs
        f1   = fftn(region1,[Sy Sx]);
        f2   = fftn(region2,[Sy Sx]);
        P21  = f2.*conj(f1);
        W = ones(Ny,Nx);
        Wden = sqrt(P21.*conj(P21));
        W(P21~=0) = Wden(P21~=0);
        R = P21./W;
        R = R(fftindy,fftindx);
        
        %SVD-based Phase Correlation
        [u,s,v]=svd(R);
        v=unwrap(angle(v(:,1)));
        um=(v-v(Sx/2+1))';
        u=unwrap(angle(u(:,1)));
        vm=(u-u(Sy/2+1))';

        if (s(1,1)/s(2,2)>1.5 && t>1) || t==1
            um_cum=[um_cum,um];
            vm_cum=[vm_cum,vm];
            wt_cum=[wt_cum,wt];
            lsqX_cum=[lsqX_cum,lsqX{t}];
            lsqY_cum=[lsqY_cum,lsqY{t}];
            t_opt(n)=t;
        end

%         wt_cum=[wt_cum,wt.*s(1,1)./s(2,2)];
%         wt_cum=[wt_cum,wt.*(s(1,1)./s(2,2)-1)];
        
        U(n)= wlsq(um_cum,lsqX_cum,wt_cum)*Sx/2/pi;
        V(n)=-wlsq(vm_cum,lsqY_cum,wt_cum)*Sy/2/pi;
        
%         U(n)= wlsq(um_cum,[lsqX{1:t}],repmat(wt,[1,t]))*Sx/2/pi;
%         V(n)=-wlsq(vm_cum,[lsqY{1:t}],repmat(wt,[1,t]))*Sy/2/pi;
        

        
        if t<size(im1,3)
            %Displacement cutoff
            if U(n)*dt(t+1)>res(1)/4 || V(n)*dt(t+1)>res(2)/4
                break
            end
        end
    end
    if Peakswitch
        C(n,:)=diag(s(1:3,1:3));
    end
end
%add DWO to estimation
U = round(Uin)+U;
V = round(Vin)+V;

function [X,Y]=IMgrid(L,S,G)
% --- Grid Generation Subfunction ---

%grid buffer
if nargin<3
    G=[0 0 0 0];
end

S=[S(2) S(1)];
G=[G(2) G(1) L(1)-G(2)+1 L(2)-G(1)+1];

%form grid
if max(S)==0
    %pixel grid
    y=(1:L(1))';
    x=1:L(2);
else
    if G(1)==0
        %buffers 1/2 grid spacing
        y=(ceil((L(1)-(floor(L(1)/S(1))-2)*S(1))/2):S(1):(L(1)-S(1)))';
    else
        %predefined grid buffer
        y=(G(1):S(1):G(3))';
    end
    if G(2)==0
        %buffers 1/2 grid spacing
        x=ceil((L(2)-(floor(L(2)/S(2))-2)*S(2))/2):S(2):(L(2)-S(2));
    else
        %predefined grid buffer
        x=(G(2):S(2):G(4));
    end
end

%vector2matrix conversion
X=x(ones(length(y),1),:);
Y=y(:,ones(1,length(x)));

function [ZI]=VFinterp(X,Y,Z,XI,YI,M)
% --- Velocity Interpolation Subfunction

%find grid sizes
Method={'nearest','linear','cubic'};
L=[max(max(YI)) max(max(XI))];
S=size(X);

%buffer matrix with nearest neighbor approximation for image boundaries
Xf = [1 X(1,:) L(2); ones(S(1),1) X L(2)*ones(S(1),1); 1 X(1,:) L(2);];
Yf = [ones(1,S(2)+2); Y(:,1) Y Y(:,1); L(1)*ones(1,S(2)+2)];
Zf = zeros(S+2);
Zf(2:end-1,2:end-1)=Z;
Zf(1,2:end-1)   = (Z(1,:)-Z(2,:))./(Y(1,:)-Y(2,:)).*(1-Y(2,:))+Z(1,:);
Zf(end,2:end-1) = (Z(end,:)-Z(end-1,:))./(Y(end,:)-Y(end-1,:)).*(L(1)-Y(end-1,:))+Z(end,:);
Zf(2:end-1,1)   = (Z(:,1)-Z(:,2))./(X(:,1)-X(:,2)).*(1-X(:,2))+Z(:,1);
Zf(2:end-1,end) = (Z(:,end)-Z(:,end-1))./(X(:,end)-X(:,end-1)).*(L(2)-X(:,end-1))+Z(:,end);
Zf(1,1)     = mean([Zf(2,1) Zf(1,2)]);
Zf(end,1)   = mean([Zf(end-1,1) Zf(end,2)]);
Zf(1,end)   = mean([Zf(2,end) Zf(1,end-1)]);
Zf(end,end) = mean([Zf(end-1,end) Zf(end,end-1)]);

%velocity interpolation
ZI=interp2(Xf,Yf,Zf,XI,YI,char(Method(M)));

function [Uf,Vf]=VELfilt(U,V,C)
% --- Velocity Smoothing Subfunction ---

%2D gaussian filtering
A=fspecial('gaussian',[7 7],C);
Uf=imfilter(U,A,'replicate');
Vf=imfilter(V,A,'replicate');

function [W]=windowmask(N,R)
% --- Gaussian Window Mask Subfunction ---

% %generic indices
x  = -1:2/(N(1)-1):1;
y  = (-1:2/(N(2)-1):1)';
% 
% %gaussian window sizes
% px = (1.224*N(1)/R(1))^1.0172;
% py = (1.224*N(2)/R(2))^1.0172;
[px]=findwidth(R(1)/N(1));
[py]=findwidth(R(2)/N(2));
% 
% %generate 2D window
wx=exp(-px^2.*x.^2/2);
wy=exp(-py^2.*y.^2/2);

W  = wy*wx;

function [W]=energyfilt(Nx,Ny,d,q)
% --- RPC Spectral Filter Subfunction ---

%assume no aliasing
if nargin<4
    q = 0;
end

%initialize indices
[k1,k2]=meshgrid(-pi:2*pi/Ny:pi-2*pi/Ny,-pi:2*pi/Nx:pi-2*pi/Nx);

%particle-image spectrum
Ep = (pi*255*d^2/8)^2*exp(-d^2*k1.^2/16).*exp(-d^2*k2.^2/16);

%aliased particle-image spectrum
Ea = (pi*255*d^2/8)^2*exp(-d^2*(k1+2*pi).^2/16).*exp(-d^2*(k2+2*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1-2*pi).^2/16).*exp(-d^2*(k2+2*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1+2*pi).^2/16).*exp(-d^2*(k2-2*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1-2*pi).^2/16).*exp(-d^2*(k2-2*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1+0*pi).^2/16).*exp(-d^2*(k2+2*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1+0*pi).^2/16).*exp(-d^2*(k2-2*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1+2*pi).^2/16).*exp(-d^2*(k2+0*pi).^2/16)+...
     (pi*255*d^2/8)^2*exp(-d^2*(k1-2*pi).^2/16).*exp(-d^2*(k2+0*pi).^2/16);

%noise spectrum
En = pi/4*Nx*Ny;

%DPIV SNR spectral filter
W  = Ep./((1-q)*En+(q)*Ea);
W  = W'/max(max(W));

function [u,v,M]=subpixel(G,ccsizex,ccsizey,W,Method,Peakswitch)
%intialize indices
cc_x = -ccsizex/2:ccsizex/2-1;
cc_y = -ccsizey/2:ccsizey/2-1;

%find maximum correlation value
[M,I] = max(G(:));

%if correlation empty
if M==0
    if Peakswitch
        u=zeros(1,3);
        v=zeros(1,3);
        M=zeros(1,3);
    else
        u=0; v=0;
    end
else
    if Peakswitch
        %Locate peaks using imregionalmax
        A=imregionalmax(G);
        peakmat=G.*A;
        for i=2:3
            peakmat(peakmat==M(i-1))=0;
            [M(i),I(i)]=max(peakmat(:));
        end
        j=length(M);
    else
        j=1;    
    end
    
    for i=1:j
        method=Method;
        
        %find x and y indices
        shift_locy = 1+mod(I(i)-1,ccsizey);
        shift_locx = ceil(I(i)/ccsizey);

        shift_errx=[];
        shift_erry=[];
        %find subpixel displacement in x
        if shift_locx == 1
            %boundary condition 1
            shift_errx =  G( shift_locy , shift_locx+1 )/M(i); method=1;
        elseif shift_locx == ccsizex
            %boundary condition 2
            shift_errx = -G( shift_locy , shift_locx-1 )/M(i); method=1;
        elseif G( shift_locy , shift_locx+1 ) == 0
            %endpoint discontinuity 1
            shift_errx = -G( shift_locy , shift_locx-1 )/M(i); method=1;
        elseif G( shift_locy , shift_locx-1 ) == 0
            %endpoint discontinuity 2
            shift_errx =  G( shift_locy , shift_locx+1 )/M(i); method=1;
        end
        if shift_locy == 1
            %boundary condition 1
            shift_erry = -G( shift_locy+1 , shift_locx )/M(i); method=1;
        elseif shift_locy == ccsizey
            %boundary condition 2
            shift_erry =  G( shift_locy-1 , shift_locx )/M(i); method=1;
        elseif G( shift_locy+1 , shift_locx ) == 0
            %endpoint discontinuity 1
            shift_erry =  G( shift_locy-1 , shift_locx )/M(i); method=1;
        elseif G( shift_locy-1 , shift_locx ) == 0
            %endpoint discontinuity 2
            shift_erry = -G( shift_locy+1 , shift_locx )/M(i); method=1;
        end

        if method==2
            
            %%%%%%%%%%%%%%%%%%%%
            % 4-Point Gaussian %
            %%%%%%%%%%%%%%%%%%%%
            
            %Since the case where M is located at a border will default to
            %the 3-point gaussian and we don't have to deal with
            %saturation, just use 4 points in a tetris block formation:
            %
            %             *
            %            ***
            
            points=[shift_locy   shift_locx   G(shift_locy  ,shift_locx  );...
                    shift_locy-1 shift_locx   G(shift_locy-1,shift_locx  );...
                    shift_locy   shift_locx-1 G(shift_locy  ,shift_locx-1);...
                    shift_locy   shift_locx+1 G(shift_locy  ,shift_locx+1)];
                
            [Isort,IsortI] = sort(points(:,3),'descend');
            points = points(IsortI,:);

            x1=points(1,2); x2=points(2,2); x3=points(3,2); x4=points(4,2);
            y1=points(1,1); y2=points(2,1); y3=points(3,1); y4=points(4,1);
            a1=points(1,3); a2=points(2,3); a3=points(3,3); a4=points(4,3);

            alpha(1) = (x4^2)*(y2 - y3) + (x3^2)*(y4 - y2) + ((x2^2) + (y2 - y3)*(y2 - y4))*(y3 - y4);
            alpha(2) = (x4^2)*(y3 - y1) + (x3^2)*(y1 - y4) - ((x1^2) + (y1 - y3)*(y1 - y4))*(y3 - y4);
            alpha(3) = (x4^2)*(y1 - y2) + (x2^2)*(y4 - y1) + ((x1^2) + (y1 - y2)*(y1 - y4))*(y2 - y4);
            alpha(4) = (x3^2)*(y2 - y1) + (x2^2)*(y1 - y3) - ((x1^2) + (y1 - y2)*(y1 - y3))*(y2 - y3);

            gamma(1) = (-x3^2)*x4 + (x2^2)*(x4 - x3) + x4*((y2^2) - (y3^2)) + x3*((x4^2) - (y2^2) + (y4^2)) + x2*(( x3^2) - (x4^2) + (y3^2) - (y4^2));
            gamma(2) = ( x3^2)*x4 + (x1^2)*(x3 - x4) + x4*((y3^2) - (y1^2)) - x3*((x4^2) - (y1^2) + (y4^2)) + x1*((-x3^2) + (x4^2) - (y3^2) + (y4^2));
            gamma(3) = (-x2^2)*x4 + (x1^2)*(x4 - x2) + x4*((y1^2) - (y2^2)) + x2*((x4^2) - (y1^2) + (y4^2)) + x1*(( x2^2) - (x4^2) + (y2^2) - (y4^2));
            gamma(4) = ( x2^2)*x3 + (x1^2)*(x2 - x3) + x3*((y2^2) - (y1^2)) - x2*((x3^2) - (y1^2) + (y3^2)) + x1*((-x2^2) + (x3^2) - (y2^2) + (y3^2));

            delta(1) = x4*(y2 - y3) + x2*(y3 - y4) + x3*(y4 - y2);
            delta(2) = x4*(y3 - y1) + x3*(y1 - y4) + x1*(y4 - y3);
            delta(3) = x4*(y1 - y2) + x1*(y2 - y4) + x2*(y4 - y1);
            delta(4) = x3*(y2 - y1) + x2*(y1 - y3) + x1*(y3 - y2);

            deno = 2*(log(a1)*delta(1) + log(a2)*delta(2) + log(a3)*delta(3) + log(a4)*delta(4));

            x_centroid = (log(a1)*alpha(1) + log(a2)*alpha(2) + log(a3)*alpha(3) + log(a4)*alpha(4))/deno;
            y_centroid = (log(a1)*gamma(1) + log(a2)*gamma(2) + log(a3)*gamma(3) + log(a4)*gamma(4))/deno;
            shift_errx=x_centroid-shift_locx;
            shift_erry=y_centroid-shift_locy;
            
        elseif method==3
            
            %%%%%%%%%%%%%%%%%%%%%%%%%%
            % Gaussian Least Squares %
            %%%%%%%%%%%%%%%%%%%%%%%%%%
            
            %Find a suitable window around the peak (5x5 preferred)
            x_min=shift_locx-2; x_max=shift_locx+2;
            y_min=shift_locy-2; y_max=shift_locy+2;
            if x_min<1
                x_min=1;
            end
            if x_max>ccsizex
                x_max=ccsizex;
            end
            if y_min<1
                y_min=1;
            end
            if y_max>ccsizey
                y_max=ccsizey;
            end
            points=G(y_min:y_max,x_min:x_max).*W(y_min:y_max,x_min:x_max);
            
            %Options for the lsqnonlin solver
            options=optimset('MaxIter',1200,'MaxFunEvals',5000,'TolX',5e-6,'TolFun',5e-6,...
                'LargeScale','off','Display','off','DiffMinChange',1e-7,'DiffMaxChange',1,...
                'Algorithm','levenberg-marquardt');
            
            %Initial values for the solver
            x0=[M(i) 1 shift_locx shift_locy];

            [xloc yloc]=meshgrid(x_min:x_max,y_min:y_max);

            %Run solver; default to 3-point gauss if it fails
            try
                xvars=lsqnonlin(@leastsquares2D,x0,[],[],options,points(:),[yloc(:),xloc(:)]);
                shift_errx=xvars(3)-shift_locx;
                shift_erry=xvars(4)-shift_locy;
            catch
                method=1;
            end
        end
        if method==1
            
            %%%%%%%%%%%%%%%%%%%%
            % 3-Point Gaussian %
            %%%%%%%%%%%%%%%%%%%%
            
            if isempty(shift_errx)
                %gaussian fit
                lCm1 = log(G( shift_locy , shift_locx-1 )*W( shift_locy , shift_locx-1 ));
                lC00 = log(G( shift_locy , shift_locx   )*W( shift_locy , shift_locx   ));
                lCp1 = log(G( shift_locy , shift_locx+1 )*W( shift_locy , shift_locx+1 ));
                if (2*(lCm1+lCp1-2*lC00)) == 0
                    shift_errx = 0;
                else
                    shift_errx = (lCm1-lCp1)/(2*(lCm1+lCp1-2*lC00));
                end
            end
            if isempty(shift_erry)
                lCm1 = log(G( shift_locy-1 , shift_locx )*W( shift_locy-1 , shift_locx ));
                lC00 = log(G( shift_locy   , shift_locx )*W( shift_locy   , shift_locx ));
                lCp1 = log(G( shift_locy+1 , shift_locx )*W( shift_locy+1 , shift_locx ));
                if (2*(lCm1+lCp1-2*lC00)) == 0
                    shift_erry = 0;
                else
                    shift_erry = (lCm1-lCp1)/(2*(lCm1+lCp1-2*lC00));
                end
            end
            
        end
        
        u(i)=cc_x(shift_locx)+shift_errx;
        v(i)=cc_y(shift_locy)+shift_erry;
        
        if isinf(u(i)) || isinf(v(i))
            u(i)=0; v(i)=0;
        end
    end
end

function F = leastsquares2D(x,mapint_i,locxy_i)
%This function is called by lsqnonlin if the least squares or continuous
%least squares method has been chosen. x contains initial guesses[I0, betas, x_c,
%y_c]. mapint_i is a matrix containing pixel intensity values, and locxy_i
%is a 1x2 vector containing the row/column coordinates of the top left
%pixel in mapint_i
%
%F is the variable being minimized - the difference between the gaussian
%curve and the actual intensity values.
%
%Adapted from M. Brady's 'leastsquaresgaussfit' and 'mapintensity'
%B.Drew - 7.18.2008

I0=x(1);
betas=x(2);
x_centroid=x(3);
y_centroid=x(4);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%Just like in the continuous four-point method, lsqnonlin tries negative
%values for x(2), which will return errors unless the abs() function is
%used in front of all the x(2)'s.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

num1=(I0*pi)/4;
num2=sqrt(abs(betas));

gauss_int = zeros(size(mapint_i));
xp = zeros(size(mapint_i));
yp = zeros(size(mapint_i));
for ii = 1:length(mapint_i)
    xp(ii) = locxy_i(ii,2);
    yp(ii) = locxy_i(ii,1);
end

% map an intensity profile of a gaussian function:
for rr = 1:size(xp,1)
    gauss_int(rr)=I0*exp(-abs(betas)*(((xp(rr))-x_centroid)^2 + ...
        ((yp(rr))-y_centroid)^2));
end

% compare the Gaussian curve to the actual pixel intensities
F=mapint_i-gauss_int;


function [Uval,Vval,Evalval,Cval]=VAL(X,Y,U,V,Eval,C,Threshswitch,UODswitch,Bootswitch,extrapeaks,Uthresh,Vthresh,UODwinsize,UODthresh,Bootper,Bootiter,Bootkmax)
% --- Validation Subfunction ---
if extrapeaks
    j=3;
else
    j=1;
end

[X,Y,U,V,Eval,C]=matrixform(X,Y,U,V,Eval,C);
Uval=U(:,:,1);Vval=V(:,:,1);Evalval=Eval(:,:,1);
if ~isempty(C)
    Cval=C(:,:,1);
else
    Cval=[];
end
S=size(X);

if Threshswitch || UODswitch
    for i=1:j
        %Thresholding
        if Threshswitch
            [Uval,Vval,Evalval] = Thresh(Uval,Vval,Uthresh,Vthresh,Evalval);
        end

        %Univeral Outlier Detection
        if UODswitch
            t=permute(UODwinsize,[2 3 1]);
            t=t(:,t(1,:)~=0);
            [Uval,Vval,Evalval] = UOD(Uval,Vval,t',UODthresh,Evalval);
        end
%         disp([num2str(sum(sum(Evalval>0))),' bad vectors'])
        %Try additional peaks where validation failed
        if i<j
            Utemp=U(:,:,i+1);Vtemp=V(:,:,i+1);Evaltemp=Eval(:,:,i+1);Ctemp=C(:,:,i+1);
            Uval(Evalval>0)=Utemp(Evalval>0);
            Vval(Evalval>0)=Vtemp(Evalval>0);
            Evalval(Evalval>0)=Evaltemp(Evalval>0);
            Cval(Evalval>0)=Ctemp(Evalval>0);
        end
    end
end

%replacement
for i=1:S(1)
    for j=1:S(2)
        if Evalval(i,j)>0 && Evalval(i,j)<200
            %initialize replacement search size
            q=0;
            s=0;

            %get replacement block with at least 8 valid points
            while s==0
                q=q+1;
                Imin = max([i-q 1   ]);
                Imax = min([i+q S(1)]);
                Jmin = max([j-q 1   ]);
                Jmax = min([j+q S(2)]);
                Iind = Imin:Imax;
                Jind = Jmin:Jmax;
                Ublock = Uval(Iind,Jind);
                if length(Ublock(~isnan(Ublock)))>=8
                    Xblock = X(Iind,Jind)-X(i,j);
                    Yblock = Y(Iind,Jind)-Y(i,j);
                    Vblock = Vval(Iind,Jind);
                    s=1;
                end
            end
            
            %distance from erroneous vector
            Dblock = (Xblock.^2+Yblock.^2).^0.5;
            Dblock(isnan(Ublock))=nan;

            %validated vector
            Uval(i,j) = nansum(nansum(Dblock.*Ublock))/nansum(nansum(Dblock));
            Vval(i,j) = nansum(nansum(Dblock.*Vblock))/nansum(nansum(Dblock));       
        end
    end
end

%Bootstrapping
if Bootswitch
    [Uval,Vval,Evalval] = bootstrapping(X,Y,Uval,Vval,Bootper,Bootiter,Bootkmax,Evalval);
end

%convert back to vector
[Uval,Vval,Evalval,Cval]=vectorform(X,Y,Uval,Vval,Evalval,Cval);

function [U,V,Eval] = Thresh(U,V,uthreshold,vthreshold,Eval)
% --- Thresholding Validation Subfunction ---

%neglect u and v threshold
if nargin<=4
    uthreshold = [-inf inf];
    vthreshold = [-inf inf];
end

S=size(U);

%thresholding
for i=1:S(1)
    for j=1:S(2)
        if Eval(i,j)==0
            %velocity threshold condition
            if U(i,j)<uthreshold(1) || U(i,j)>uthreshold(2) || V(i,j)<vthreshold(1) || V(i,j)>vthreshold(2)
                U(i,j)=nan;
                V(i,j)=nan;
                Eval(i,j)=100;
            end
        elseif Eval(i,j)==-1
            %boundary condition
            U(i,j)=nan;
            V(i,j)=nan;
        end
    end
end

function [U,V,Eval] = UOD(U,V,t,tol,Eval)
% --- Universal Outlier Detection Validation Subfunction ---

%number of validation passes
pass = length(tol);

S=size(U);

%outlier searching
for k=1:pass
    
    q = (t(k,:)-1)/2;
    
    for i=1:S(1)
        for j=1:S(2)
            if Eval(i,j)==0           
                %get evaluation block with at least 8 valid points
                s=0;
                while s==0
                    Imin = max([i-q(2) 1   ]);
                    Imax = min([i+q(2) S(1)]);
                    Jmin = max([j-q(1) 1   ]);
                    Jmax = min([j+q(1) S(2)]);
                    Iind = Imin:Imax;
                    Jind = Jmin:Jmax;
                    Ublock = U(Iind,Jind);
                    if length(Ublock(~isnan(Ublock)))>=8
%                         Xblock = X(Iind,Jind)-X(i,j);
%                         Yblock = Y(Iind,Jind)-Y(i,j);
                        Vblock = V(Iind,Jind);
                        s=1;
                    else
                        q=q+1;
                    end
                end

%                 %distance from vector location
%                 Dblock = (Xblock.^2+Yblock.^2).^0.5;
%                 Dblock(isnan(Ublock))=nan;

                %universal outlier detection
                Ipos = find(Iind==i);
                Jpos = find(Jind==j);
                [Ru]=UOD_sub(Ublock,Ipos,Jpos);
                [Rv]=UOD_sub(Vblock,Ipos,Jpos);

                if Ru > tol(k) || Rv > tol(k)
                    %UOD threshold condition
                    U(i,j)=nan;
                    V(i,j)=nan;
                    Eval(i,j)=k;
                end

            end

        end
    end
end

function [R]=UOD_sub(W,p,q)
% --- Universal Outlier Detection Algorithm ---

%minimum variance assumption
e=0.1; 

%remove value from query point
x=W(p,q);
W(p,q)=nan;

%remove any erroneous points
P=W(:);
Ps = sort(P);
Psfull = Ps(~isnan(Ps));
N=length(Psfull);

if N<=floor(length(W)/3)
    %return negative threshold value if no valid vectors in block
    R = inf;
else
    %return the median deviation normalized to the MAD
    if mod(N,2)==0
        M = (Psfull(N/2)+Psfull(N/2+1))/2;
        MADfull = sort(abs(Psfull-M));
        Q = (MADfull(N/2)+MADfull(N/2+1))/2;
        R = abs(x-M)/(Q+e);
    else
        M = Psfull((N+1)/2);
        MADfull = sort(abs(Psfull-M));
        Q = MADfull((N+1)/2);
        R = abs(x-M)/(Q+e);
    end
end

function [U,V,Eval] = bootstrapping(X,Y,U,V,per,iter,kmax,Eval)
% Bootstrapping Validation Subfunction 
%
% [U,V,Eval] = bootstraping(x,y,u,v,per,iter,kmax,Eval)
%
% per  = percent removed for each interpolation (0-1)
% iter = number of interpolations per frame (for histogram)
% kmax = number of passes 

n = size(X);

M = zeros(n(1),n(2),iter);

tol = 0.3;
ktol = 1;

while tol > 0 && ktol <= kmax+1
    U = zeros(n(1),n(2),iter);
    V = zeros(n(1),n(2),iter);

    for i = 1:iter
        clear S m Up Vp Ui Vi
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Data Removal
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

        [m]= bootstrapping_dataremove(size(U),per,sum(Eval,3));

        S(:,1) = X(m==1);
        S(:,2) = Y(m==1);

        Up = U(m==1);
        Vp = V(m==1);
        M(:,:,i) = m;
        
        Ui = gridfit(S(:,1),S(:,2),Up,X(1,:),Y(:,1));
        Vi = gridfit(S(:,1),S(:,2),Vp,X(1,:),Y(:,1));
        U(:,:,i) = Ui;
        V(:,:,i) = Vi;

    end

    PBad = 0;
    for j = 1:n(1)
        for k = 1:n(2)
            if sum(isnan(U(j,k,:))) == 0
                try              
                    [H.U,HX.U] = hist(U(j,k,:),iter/2);
                    [H.V,HX.V] = hist(V(j,k,:),iter/2);

                    modeU = HX.U(H.U==max(H.U));
                    modeV = HX.V(H.V==max(H.V));

                    tU = abs((modeU - U(j,k))/modeU);
                    tV = abs((modeV - V(j,k))/modeV);
                    if tU > tol || tV > tol && Eval(j,k) ~= -1
                        U(j,k) = modeU(1);
                        V(j,k) = modeV(1);
                        Eval(j,k) = 200;
                        PBad = PBad+1;
                    end
                catch%#ok
                    Ems=lasterror;%#ok
                    fprintf('\n\n')
                    fprintf(Ems.message)
                end
            end
        end
    end
    ktol = ktol + 1;
    tol = tol-(tol/(kmax-1))*(ktol-1);
end

function [M1] = bootstrapping_dataremove(DSIZE,ENUM,MASK)
% --- Bootstrapping Data Removal ---

Nx = DSIZE(1);
Ny = DSIZE(2);
Nt = 1;

M1   = zeros(DSIZE);
RMAT = rand(Nx,Ny,Nt);
EN   = 0;

while sum(M1(:))/(Nx*Ny) < ENUM && EN < 1
    M1 = RMAT<EN;
    M1(MASK<0) = 0; 
    EN = EN + 0.005;    
end

M1 = double(M1);

function [zgrid,xgrid,ygrid] = gridfit(x,y,z,xnodes,ynodes,varargin)
% gridfit: estimates a surface on a 2d grid, based on scattered data
%          Replicates are allowed. All methods extrapolate to the grid
%          boundaries. Gridfit uses a modified ridge estimator to
%          generate the surface, where the bias is toward smoothness.
%
%          Gridfit is not an interpolant. Its goal is a smooth surface
%          that approximates your data, but allows you to control the
%          amount of smoothing.
%
% usage #1: zgrid = gridfit(x,y,z,xnodes,ynodes);
% usage #2: [zgrid,xgrid,ygrid] = gridfit(x,y,z,xnodes,ynodes);
% usage #3: zgrid = gridfit(x,y,z,xnodes,ynodes,prop,val,prop,val,...);
%
% Arguments: (input)
%  x,y,z - vectors of equal lengths, containing arbitrary scattered data
%          The only constraint on x and y is they cannot ALL fall on a
%          single line in the x-y plane. Replicate points will be treated
%          in a least squares sense.
%
%          ANY points containing a NaN are ignored in the estimation
%
%  xnodes - vector defining the nodes in the grid in the independent
%          variable (x). xnodes need not be equally spaced. xnodes
%          must completely span the data. If they do not, then the
%          'extend' property is applied, adjusting the first and last
%          nodes to be extended as necessary. See below for a complete
%          description of the 'extend' property.
%
%          If xnodes is a scalar integer, then it specifies the number
%          of equally spaced nodes between the min and max of the data.
%
%  ynodes - vector defining the nodes in the grid in the independent
%          variable (y). ynodes need not be equally spaced.
%
%          If ynodes is a scalar integer, then it specifies the number
%          of equally spaced nodes between the min and max of the data.

% set defaults
params.smoothness = 1;
params.interp = 'triangle';
params.regularizer = 'gradient';
params.solver = 'normal';
params.maxiter = [];
params.extend = 'warning';

% and check for any overrides
params = parse_pv_pairs(params,varargin);

% check the parameters for acceptability
% smoothness == 1 by default
if isempty(params.smoothness)
  params.smoothness = 1;
else
  if (params.smoothness<=0)
    error 'Smoothness must be real, finite, and positive.'
  end
end
% regularizer  - must be one of 4 options - the second and
% third are actually synonyms.
valid = {'springs', 'diffusion', 'laplacian', 'gradient'};
if isempty(params.regularizer)
  params.regularizer = 'diffusion';
end
ind = strmatch(lower(params.regularizer),valid);
if (length(ind)==1)
  params.regularizer = valid{ind};
else
  error(['Invalid regularization method: ',params.regularizer])
end

% interp must be one of:
%    'bilinear', 'nearest', or 'triangle'
% but accept any shortening thereof.
valid = {'bilinear', 'nearest', 'triangle'};
if isempty(params.interp)
  params.interp = 'triangle';
end
ind = strmatch(lower(params.interp),valid);
if (length(ind)==1)
  params.interp = valid{ind};
else
  error(['Invalid interpolation method: ',params.interp])
end

% solver must be one of:
%    'backslash', '\', 'symmlq', 'lsqr', or 'normal'
% but accept any shortening thereof.
valid = {'backslash', '\', 'symmlq', 'lsqr', 'normal'};
if isempty(params.solver)
  params.solver = '\';
end
ind = strmatch(lower(params.solver),valid);
if (length(ind)==1)
  params.solver = valid{ind};
else
  error(['Invalid solver option: ',params.solver])
end

% extend must be one of:
%    'never', 'warning', 'always'
% but accept any shortening thereof.
valid = {'never', 'warning', 'always'};
if isempty(params.extend)
  params.extend = 'warning';
end
ind = strmatch(lower(params.extend),valid);
if (length(ind)==1)
  params.extend = valid{ind};
else
  error(['Invalid extend option: ',params.extend])
end

% ensure all of x,y,z,xnodes,ynodes are column vectors,
% also drop any NaN data
x=x(:);
y=y(:);
z=z(:);
k = isnan(x) | isnan(y) | isnan(z);
if any(k)
  x(k)=[];
  y(k)=[];
  z(k)=[];
end
xmin = min(x);
xmax = max(x);
ymin = min(y);
ymax = max(y);

% did they supply a scalar for the nodes?
if length(xnodes)==1
  xnodes = linspace(xmin,xmax,xnodes)';
  xnodes(end) = xmax; % make sure it hits the max
end
if length(ynodes)==1
  ynodes = linspace(ymin,ymax,ynodes)';
  ynodes(end) = ymax; % make sure it hits the max
end

xnodes=xnodes(:);
ynodes=ynodes(:);
dx = diff(xnodes);
dy = diff(ynodes);
nx = length(xnodes);
ny = length(ynodes);
ngrid = nx*ny;

% default for maxiter?
if isempty(params.maxiter)
  params.maxiter = min(10000,nx*ny);
end

% check lengths of the data
n = length(x);
if (length(y)~=n)||(length(z)~=n)
  error 'Data vectors are incompatible in size.'
end
if n<3
  error 'Insufficient data for surface estimation.'
end

% verify the nodes are distinct
if any(diff(xnodes)<=0)||any(diff(ynodes)<=0)
  error 'xnodes and ynodes must be monotone increasing'
end

% do we need to tweak the first or last node in x or y?
if xmin<xnodes(1)
    xnodes(1) = xmin;
end
if xmax>xnodes(end)
    xnodes(end) = xmax;
end
if ymin<ynodes(1)
    ynodes(1) = ymin;
end
if ymax>ynodes(end)
    ynodes(end) = ymax;
end

% only generate xgrid and ygrid if requested.
if nargout>1
  [xgrid,ygrid]=meshgrid(xnodes,ynodes);
end

% determine which cell in the array each point lies in
[junk,indx] = histc(x,xnodes);
[junk,indy] = histc(y,ynodes);
% any point falling at the last node is taken to be
% inside the last cell in x or y.
k=(indx==nx);
indx(k)=indx(k)-1;
k=(indy==ny);
indy(k)=indy(k)-1;

% interpolation equations for each point
tx = min(1,max(0,(x - xnodes(indx))./dx(indx)));
ty = min(1,max(0,(y - ynodes(indy))./dy(indy)));
ind = indy + ny*(indx-1);
% Future enhancement: add cubic interpolant
switch params.interp
  case 'triangle'
    % linear interpolation inside each triangle
    k = (tx > ty);
    L = ones(n,1);
    L(k) = ny;
    
    t1 = min(tx,ty);
    t2 = max(tx,ty);
    A = sparse(repmat((1:n)',1,3),[ind,ind+ny+1,ind+L], ...
       [1-t2,t1,t2-t1],n,ngrid);
    
  case 'nearest'
    % nearest neighbor interpolation in a cell
    k = round(1-ty) + round(1-tx)*ny;
    A = sparse((1:n)',ind+k,ones(n,1),n,ngrid);
    
  case 'bilinear'
    % bilinear interpolation in a cell
    A = sparse(repmat((1:n)',1,4),[ind,ind+1,ind+ny,ind+ny+1], ...
       [(1-tx).*(1-ty), (1-tx).*ty, tx.*(1-ty), tx.*ty], ...
       n,ngrid);
    
end
rhs = z;

% Build regularizer. Add del^4 regularizer one day.
switch params.regularizer
  case 'springs'
    % zero "rest length" springs
    [i,j] = meshgrid(1:nx,1:(ny-1));
    ind = j(:) + ny*(i(:)-1);
    m = nx*(ny-1);
    stiffness = 1./dy;
    Areg = sparse(repmat((1:m)',1,2),[ind,ind+1], ...
       stiffness(j(:))*[-1 1],m,ngrid);
    
    [i,j] = meshgrid(1:(nx-1),1:ny);
    ind = j(:) + ny*(i(:)-1);
    m = (nx-1)*ny;
    stiffness = 1./dx;
    Areg = [Areg;sparse(repmat((1:m)',1,2),[ind,ind+ny], ...
       stiffness(i(:))*[-1 1],m,ngrid)];
    
    [i,j] = meshgrid(1:(nx-1),1:(ny-1));
    ind = j(:) + ny*(i(:)-1);
    m = (nx-1)*(ny-1);
    stiffness = 1./sqrt(dx(i(:)).^2 + dy(j(:)).^2);
    Areg = [Areg;sparse(repmat((1:m)',1,2),[ind,ind+ny+1], ...
       stiffness*[-1 1],m,ngrid)];
    
    Areg = [Areg;sparse(repmat((1:m)',1,2),[ind+1,ind+ny], ...
       stiffness*[-1 1],m,ngrid)];
    
  case {'diffusion' 'laplacian'}
    % thermal diffusion using Laplacian (del^2)
    [i,j] = meshgrid(1:nx,2:(ny-1));
    ind = j(:) + ny*(i(:)-1);
    dy1 = dy(j(:)-1);
    dy2 = dy(j(:));
    
    Areg = sparse(repmat(ind,1,3),[ind-1,ind,ind+1], ...
      [-2./(dy1.*(dy1+dy2)), 2./(dy1.*dy2), ...
       -2./(dy2.*(dy1+dy2))],ngrid,ngrid);
    
    [i,j] = meshgrid(2:(nx-1),1:ny);
    ind = j(:) + ny*(i(:)-1);
    dx1 = dx(i(:)-1);
    dx2 = dx(i(:));
    
    Areg = Areg + sparse(repmat(ind,1,3),[ind-ny,ind,ind+ny], ...
      [-2./(dx1.*(dx1+dx2)), 2./(dx1.*dx2), ...
       -2./(dx2.*(dx1+dx2))],ngrid,ngrid);
    
  case 'gradient'
    % Subtly different from the Laplacian. A point for future
    % enhancement is to do it better for the triangle interpolation
    % case.
    [i,j] = meshgrid(1:nx,2:(ny-1));
    ind = j(:) + ny*(i(:)-1);
    dy1 = dy(j(:)-1);
    dy2 = dy(j(:));

    Areg = sparse(repmat(ind,1,3),[ind-1,ind,ind+1], ...
      [-2./(dy1.*(dy1+dy2)), 2./(dy1.*dy2), ...
      -2./(dy2.*(dy1+dy2))],ngrid,ngrid);

    [i,j] = meshgrid(2:(nx-1),1:ny);
    ind = j(:) + ny*(i(:)-1);
    dx1 = dx(i(:)-1);
    dx2 = dx(i(:));

    Areg = [Areg;sparse(repmat(ind,1,3),[ind-ny,ind,ind+ny], ...
      [-2./(dx1.*(dx1+dx2)), 2./(dx1.*dx2), ...
      -2./(dx2.*(dx1+dx2))],ngrid,ngrid)];

end
nreg = size(Areg,1);

% Append the regularizer to the interpolation equations,
% scaling the problem first. Use the 1-norm for speed.
NA = norm(A,1);
NR = norm(Areg,1);
A = [A;Areg*(params.smoothness*NA/NR)];
rhs = [rhs;zeros(nreg,1)];

% solve the full system, with regularizer attached
switch params.solver
  case {'\' 'backslash'}
    % permute for minimum fill in for R (in the QR)
    p = colamd(A);
    zgrid=zeros(ny,nx);
    zgrid(p) = A(:,p)\rhs;
    
  case 'normal'
    % The normal equations, solved with \. Can be fast
    % for huge numbers of data points.
    
    % Permute for minimum fill-in for \ (in chol)
    APA = A'*A;
    p = symamd(APA);
    zgrid=zeros(ny,nx);
    zgrid(p) = APA(p,p)\(A(:,p)'*rhs);
    
  case 'symmlq'
    % iterative solver - symmlq - requires a symmetric matrix,
    % so use it to solve the normal equations. No preconditioner.
    tol = abs(max(z)-min(z))*1.e-13;
    [zgrid,flag] = symmlq(A'*A,A'*rhs,tol,params.maxiter);
    zgrid = reshape(zgrid,ny,nx);
    
    % display a warning if convergence problems
    switch flag
      case 0
        % no problems with convergence
      case 1
        % SYMMLQ iterated MAXIT times but did not converge.
        warning(['Symmlq performed ',num2str(params.maxiter), ...
          ' iterations but did not converge.'])
      case 3
        % SYMMLQ stagnated, successive iterates were the same
        warning 'Symmlq stagnated without apparent convergence.'
      otherwise
        warning(['One of the scalar quantities calculated in',...
          ' symmlq was too small or too large to continue computing.'])
    end
    
  case 'lsqr'
    % iterative solver - lsqr. No preconditioner here.
    tol = abs(max(z)-min(z))*1.e-13;
    [zgrid,flag] = lsqr(A,rhs,tol,params.maxiter);
    zgrid = reshape(zgrid,ny,nx);
    
    % display a warning if convergence problems
    switch flag
      case 0
        % no problems with convergence
      case 1
        % lsqr iterated MAXIT times but did not converge.
        warning(['Lsqr performed ',num2str(params.maxiter), ...
          ' iterations but did not converge.'])
      case 3
        % lsqr stagnated, successive iterates were the same
        warning 'Lsqr stagnated without apparent convergence.'
      case 4
        warning(['One of the scalar quantities calculated in',...
          ' LSQR was too small or too large to continue computing.'])
    end
    
end

function params=parse_pv_pairs(params,pv_pairs)
% parse_pv_pairs: parses sets of property value pairs
% usage: params=parse_pv_pairs(default_params,pv_pairs)
%
% arguments: (input)
%  default_params - structure, with one field for every potential
%             property/value pair. Each field will contain the default
%             value for that property. If no default is supplied for a
%             given property, then that field must be empty.
%
%  pv_array - cell array of property/value pairs.
%             Case is ignored when comparing properties to the list
%             of field names. Also, any unambiguous shortening of a
%             field/property name is allowed.
%
% arguments: (output)
%  params   - parameter struct that reflects any updated property/value
%             pairs in the pv_array.

npv = length(pv_pairs);
n = npv/2;

if n~=floor(n)
  error 'Property/value pairs must come in PAIRS.'
end
if n<=0
  % just return the defaults
  return
end

if ~isstruct(params)
  error 'No structure for defaults was supplied'
end

% there was at least one pv pair. process any supplied
propnames = fieldnames(params);
lpropnames = lower(propnames);
for i=1:n
  pi = lower(pv_pairs{2*i-1});
  vi = pv_pairs{2*i};
  
  ind = strmatch(pi,lpropnames,'exact');
  if isempty(ind)
    ind = strmatch(pi,lpropnames);
    if isempty(ind)
      error(['No matching property found for: ',pv_pairs{2*i-1}])
    elseif length(ind)>1
      error(['Ambiguous property name: ',pv_pairs{2*i-1}])
    end
  end
  pi = propnames{ind};
  
  % override the corresponding default in params
  params = setfield(params,pi,vi);
  
end

function [X,Y,U,V,Eval,C]=matrixform(x,y,u,v,eval,c)
% --- Vector to Matrix Subfunction ---

%find unique x and y grid points
a=sort(unique(x));
b=sort(unique(y));
N=length(x);

%initialize matrices
U=nan(length(b),length(a),size(u,2));
V=nan(length(b),length(a),size(v,2));
Eval=-1*ones(length(b),length(a),size(eval,2));

%generate grid matrix
[X,Y]=meshgrid(a,b);

%generate variable matrices (nans where no data available)
for i=1:size(U,3)
    for n=1:N
        I=find(b==y(n));
        J=find(a==x(n));
        U(I,J,i) = u(n,i);
        V(I,J,i) = v(n,i);
        Eval(I,J,i) = eval(n);
    end
end
if ~isempty(c)
    C=nan(length(b),length(a),size(c,2));
    for i=1:size(c,2)
        for n=1:N
            I= b==y(n);
            J= a==x(n);
            C(I,J,i)=c(n,i);
        end
    end
else
    C=[];
end

function [u,v,eval,c]=vectorform(x,y,U,V,Eval,C)
% --- Matrix to Vector Subfunction ---
x=x(:);y=y(:);
%find unique x and y grid points
a=sort(unique(x));
b=sort(unique(y));
N=length(x(:));

%initialize vectors
S=size(x(:));
u    = zeros(S);
v    = zeros(S);
eval = zeros(S);
if ~isempty(C)
    c = zeros(S);
else
    c = [];
end

%generate data vectors where data is available
for n=1:N
    I=find(b==y(n));
    J=find(a==x(n));
    u(n)    = U(I,J);
    v(n)    = V(I,J);
    eval(n) = Eval(I,J);
    if ~isempty(C)
        c(n)    = C(I,J);
    end
end

function []=write_dat_val_C(fname,X,Y,U,V,Eval,C,strand,T,frametitle,t_opt)
% --- .dat Writer Subfunction ---

if nargin<11
    t_opt=[];
end

%find I,J for plt
S = size(U);

%generate text file
fid = fopen(fname,'w');
if fid==-1
    error(['error creating file ',fname])
end

varlist='"X" "Y" "U" "V" "Eval"';

if ~isempty(C)
    varlist=[varlist,' "C"'];
    if size(U,3)>1
        for i=2:size(U,3)
            varlist=[varlist,' "U',num2str(i-1),'" "V',num2str(i-1),'"'];
        end
    end
    if size(C,3)>1
        for i=2:size(C,3)
            varlist=[varlist,' "C',num2str(i-1),'"'];
        end
    end
end
if ~isempty(t_opt)
    varlist=[varlist,' "t_opt"'];
end

%header lines
fprintf(fid,['TITLE        = "' frametitle '"\n']);
fprintf(fid,['VARIABLES    = ',varlist,'\n']);
fprintf(fid,'ZONE T="Time=%0.6f" I=%i J=%i C=BLACK STRANDID=%i SOLUTIONTIME = %0.6f\n',T,S(2),S(1),strand,T);
    

%write data
for i=1:S(1)
    for j=1:S(2)
        if isnan(U(i,j)) || isnan(V(i,j))
            %second check to ensure no nans present
            fprintf(fid,'%14.6e %14.6e %14.6e %14.6e %14.6e %14.6e',X(i,j),Y(i,j),0,0,-1);
        else
            %valid data points
            fprintf(fid,'%14.6e %14.6e %14.6e %14.6e %14.6e %14.6e',X(i,j),Y(i,j),U(i,j),V(i,j),Eval(i,j));
        end
        
        if ~isempty(C)
            if isnan(C(i,j,1))
                fprintf(fid,' %14.6e',0);
            else
                fprintf(fid,' %14.6e',C(i,j,1));
            end
            if size(U,3)>1
                for k=2:size(U,3)
                    if isnan(U(i,j,k)) || isnan(V(i,j,k))
                        fprintf(fid,' %14.6e %14.6e',0,0);
                    else
                        fprintf(fid,' %14.6e %14.6e',U(i,j,k),V(i,j,k));
                    end
                end
            end
            if size(C,3)>1
                for k=2:size(C,3)
                    if isnan(C(i,j,k))
                        fprintf(fid,' %14.6e',0);
                    else
                        fprintf(fid,' %14.6e',C(i,j,k));
                    end
                end
            end
        end
        
        if ~isempty(t_opt)
            if isnan(t_opt(i,j))
                fprintf(fid,' %14.6e',0);
            else
                fprintf(fid,' %14.6e',t_opt(i,j));
            end
        end
        
        fprintf(fid,'\n');
    end
end
    
fclose(fid);

function [p]=findwidth(r)
% --- Window Size Interpolation Function ---

R = [0.0000 0.0051 0.0052 0.0053 0.0055 0.0056 0.0057 0.0059 0.0060 ...
     0.0063 0.0064 0.0066 0.0067 0.0069 0.0070 0.0072 0.0074 0.0076 ...
     0.0079 0.0081 0.0083 0.0085 0.0087 0.0089 0.0091 0.0093 0.0095 ...
     0.0100 0.0102 0.0104 0.0107 0.0109 0.0112 0.0114 0.0117 0.0120 ...
     0.0125 0.0128 0.0131 0.0134 0.0137 0.0141 0.0144 0.0147 0.0151 ...
     0.0158 0.0161 0.0165 0.0169 0.0173 0.0177 0.0181 0.0185 0.0190 ...
     0.0199 0.0203 0.0208 0.0213 0.0218 0.0223 0.0228 0.0233 0.0239 ...
     0.0250 0.0256 0.0262 0.0268 0.0274 0.0281 0.0287 0.0294 0.0301 ...
     0.0315 0.0322 0.0330 0.0337 0.0345 0.0353 0.0361 0.0370 0.0378 ...
     0.0396 0.0406 0.0415 0.0425 0.0435 0.0445 0.0455 0.0466 0.0476 ...
     0.0499 0.0511 0.0522 0.0535 0.0547 0.0560 0.0573 0.0586 0.0600 ...
     0.0628 0.0643 0.0658 0.0673 0.0689 0.0705 0.0721 0.0738 0.0755 ...
     0.0791 0.0809 0.0828 0.0847 0.0867 0.0887 0.0908 0.0929 0.0951 ...
     0.0996 0.1019 0.1042 0.1067 0.1092 0.1117 0.1143 0.1170 0.1197 ...
     0.1253 0.1283 0.1312 0.1343 0.1374 0.1406 0.1439 0.1473 0.1507 ...
     0.1578 0.1615 0.1652 0.1691 0.1730 0.1770 0.1812 0.1854 0.1897 ...
     0.1986 0.2033 0.2080 0.2128 0.2178 0.2229 0.2281 0.2334 0.2388 ...
     0.2501 0.2559 0.2619 0.2680 0.2742 0.2806 0.2871 0.2938 0.3006 ...
     0.3148 0.3221 0.3296 0.3373 0.3451 0.3531 0.3613 0.3696 0.3781 ...
     0.3957 0.4048 0.4140 0.4233 0.4329 0.4425 0.4524 0.4623 0.4724 ...
     0.4930 0.5034 0.5139 0.5244 0.5351 0.5457 0.5564 0.5672 0.5779 ...
     0.5992 0.6099 0.6204 0.6309 0.6414 0.6517 0.6619 0.6720 0.6819 ...
     0.7014 0.7109 0.7203 0.7295 0.7385 0.7473 0.7559 0.7643 0.7726 ...
     0.7884 0.7960 0.8035 0.8107 0.8177 0.8245 0.8311 0.8376 0.8438 ...
     0.8556 0.8613 0.8667 0.8720 0.8771 0.8820 0.8867 0.8913 0.8957 ...
     0.9041 0.9080 0.9118 0.9155 0.9190 0.9224 0.9256 0.9288 0.9318 ...
     0.9374 0.9401 0.9426 0.9451 0.9474 0.9497 0.9519 0.9539 0.9559 ...
     0.9597 0.9614 0.9631 0.9647 0.9662 0.9677 0.9691 0.9705 0.9718 ...
     0.9742 0.9753 0.9764 0.9775 0.9785 0.9794 0.9803 0.9812 0.9820 ...
     0.9836 0.9843 0.9850 0.9857 0.9863 0.9869 0.9875 0.9881 0.9886 ...
     0.9896 0.9900 0.9905 0.9909 0.9913 0.9917 0.9921 0.9924 0.9928 ...
     0.9934 0.9937 0.9940 0.9943 0.9945 0.9948 0.9950 1.0000]';
 
P = [500.0000 245.4709 239.8833 234.4229 229.0868 223.8721 218.7762 213.7962 208.9296 ...
     199.5262 194.9845 190.5461 186.2087 181.9701 177.8279 173.7801 169.8244 165.9587 ...
     158.4893 154.8817 151.3561 147.9108 144.5440 141.2538 138.0384 134.8963 131.8257 ...
     125.8925 123.0269 120.2264 117.4898 114.8154 112.2018 109.6478 107.1519 104.7129 ...
     100.0000  97.7237  95.4993  93.3254  91.2011  89.1251  87.0964  85.1138  83.1764 ...
      79.4328  77.6247  75.8578  74.1310  72.4436  70.7946  69.1831  67.6083  66.0693 ...
      63.0957  61.6595  60.2560  58.8844  57.5440  56.2341  54.9541  53.7032  52.4807 ...
      50.1187  48.9779  47.8630  46.7735  45.7088  44.6684  43.6516  42.6580  41.6869 ...
      39.8107  38.9045  38.0189  37.1535  36.3078  35.4813  34.6737  33.8844  33.1131 ...
      31.6228  30.9030  30.1995  29.5121  28.8403  28.1838  27.5423  26.9153  26.3027 ...
      25.1189  24.5471  23.9883  23.4423  22.9087  22.3872  21.8776  21.3796  20.8930 ...
      19.9526  19.4984  19.0546  18.6209  18.1970  17.7828  17.3780  16.9824  16.5959 ...
      15.8489  15.4882  15.1356  14.7911  14.4544  14.1254  13.8038  13.4896  13.1826 ...
      12.5893  12.3027  12.0226  11.7490  11.4815  11.2202  10.9648  10.7152  10.4713 ...
      10.0000   9.7724   9.5499   9.3325   9.1201   8.9125   8.7096   8.5114   8.3176 ...
       7.9433   7.7625   7.5858   7.4131   7.2444   7.0795   6.9183   6.7608   6.6069 ...
       6.3096   6.1660   6.0256   5.8884   5.7544   5.6234   5.4954   5.3703   5.2481 ...
       5.0119   4.8978   4.7863   4.6774   4.5709   4.4668   4.3652   4.2658   4.1687 ...
       3.9811   3.8905   3.8019   3.7154   3.6308   3.5481   3.4674   3.3884   3.3113 ...
       3.1623   3.0903   3.0200   2.9512   2.8840   2.8184   2.7542   2.6915   2.6303 ...
       2.5119   2.4547   2.3988   2.3442   2.2909   2.2387   2.1878   2.1380   2.0893 ...
       1.9953   1.9498   1.9055   1.8621   1.8197   1.7783   1.7378   1.6982   1.6596 ...
       1.5849   1.5488   1.5136   1.4791   1.4454   1.4125   1.3804   1.3490   1.3183 ...
       1.2589   1.2303   1.2023   1.1749   1.1482   1.1220   1.0965   1.0715   1.0471 ...
       1.0000   0.9772   0.9550   0.9333   0.9120   0.8913   0.8710   0.8511   0.8318 ...
       0.7943   0.7762   0.7586   0.7413   0.7244   0.7079   0.6918   0.6761   0.6607 ...
       0.6310   0.6166   0.6026   0.5888   0.5754   0.5623   0.5495   0.5370   0.5248 ...
       0.5012   0.4898   0.4786   0.4677   0.4571   0.4467   0.4365   0.4266   0.4169 ...
       0.3981   0.3890   0.3802   0.3715   0.3631   0.3548   0.3467   0.3388   0.3311 ...
       0.3162   0.3090   0.3020   0.2951   0.2884   0.2818   0.2754   0.2692   0.2630 ...
       0.2512   0.2455   0.2399   0.2344   0.2291   0.2239   0.2188   0.2138   0.2089 ...
       0.1995   0.1950   0.1905   0.1862   0.1820   0.1778   0.1738   0.0000]';
 
p=interp1q(R,P,r);

function [xh]=wlsq(y,H,W)
% --- Weighted Least Squares Fit for Phase Correlation ---
tempmat=sortrows([y',H',W'],2);
y=tempmat(:,1);
H=tempmat(:,2);
W=diag(tempmat(:,3));

% xh=inv(H'*W*H)*H'*W*y;
xh=(H'*W*H)\(H'*W*y);