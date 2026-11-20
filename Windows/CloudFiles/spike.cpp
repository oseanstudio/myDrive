// A deliberately isolated Cloud Files API spike: real placeholder + download on open.
// This does not claim to be a remote sync provider. It owns only a fresh temporary root.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#define NTDDI_VERSION 0x0A000006
#include <windows.h>
#include <winternl.h>
#include <cfapi.h>
#include <filesystem>
#include <iostream>
#include <string>
#include <algorithm>
#include <cstring>
#pragma comment(lib,"CldApi.lib")

static const char content[]="Welcome to myDrive.\r\nThis file was hydrated on demand by the Windows Cloud Files API.\r\n";
static void CALLBACK Fetch(const CF_CALLBACK_INFO* info,const CF_CALLBACK_PARAMETERS* request) {
    CF_OPERATION_INFO operation{};operation.StructSize=sizeof(operation);operation.Type=CF_OPERATION_TYPE_TRANSFER_DATA;
    operation.ConnectionKey=info->ConnectionKey;operation.TransferKey=info->TransferKey;operation.RequestKey=info->RequestKey;
    CF_OPERATION_PARAMETERS parameters{};parameters.ParamSize=FIELD_OFFSET(CF_OPERATION_PARAMETERS,TransferData)+sizeof(parameters.TransferData);
    const auto offset=request->FetchData.RequiredFileOffset.QuadPart;
    const auto length=std::max<LONGLONG>(0,std::min<LONGLONG>(sizeof(content)-1-offset,request->FetchData.RequiredLength.QuadPart));
    parameters.TransferData.CompletionStatus=0;parameters.TransferData.Offset.QuadPart=offset;parameters.TransferData.Length.QuadPart=length;
    parameters.TransferData.Buffer=content+std::min<LONGLONG>(offset,sizeof(content)-1);
    HRESULT result=CfExecute(&operation,&parameters);
    if(FAILED(result))std::wcerr<<L"CfExecute failed: 0x"<<std::hex<<result<<L"\n";
}
static void Check(HRESULT result,const char* step){if(FAILED(result)){std::cerr<<step<<" failed: 0x"<<std::hex<<result<<"\n";throw result;}}
int wmain() {
    wchar_t temporary[MAX_PATH];if(!GetTempPathW(MAX_PATH,temporary))return 1;
    const auto root=std::filesystem::path(temporary)/(L"myDrive-CloudFiles-"+std::to_wstring(GetCurrentProcessId()));
    bool registered=false,connected=false;CF_CONNECTION_KEY connection{};int exitCode=1;
    try {
        if(std::filesystem::exists(root))throw E_UNEXPECTED;
        std::filesystem::create_directory(root);
        CF_SYNC_REGISTRATION registration{};registration.StructSize=sizeof(registration);registration.ProviderName=L"myDrive development spike";registration.ProviderVersion=L"0.1.0";
        // Stable provider GUID, only for this isolated development experiment.
        registration.ProviderId={0x6fb5d497,0x9198,0x4d7c,{0xa7,0x93,0xa2,0x6d,0xb5,0x11,0x82,0x91}};
        CF_SYNC_POLICIES policies{};policies.StructSize=sizeof(policies);policies.Hydration.Primary=CF_HYDRATION_POLICY_FULL;policies.Population.Primary=CF_POPULATION_POLICY_ALWAYS_FULL;policies.InSync=CF_INSYNC_POLICY_TRACK_ALL;
        Check(CfRegisterSyncRoot(root.c_str(),&registration,&policies,CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT),"CfRegisterSyncRoot");registered=true;
        CF_CALLBACK_REGISTRATION callbacks[]={{CF_CALLBACK_TYPE_FETCH_DATA,Fetch},CF_CALLBACK_REGISTRATION_END};
        Check(CfConnectSyncRoot(root.c_str(),callbacks,nullptr,CF_CONNECT_FLAG_NONE,&connection),"CfConnectSyncRoot");connected=true;
        CF_PLACEHOLDER_CREATE_INFO placeholder{};placeholder.RelativeFileName=L"Welcome to myDrive.txt";placeholder.FsMetadata.FileSize.QuadPart=sizeof(content)-1;placeholder.FsMetadata.BasicInfo.FileAttributes=FILE_ATTRIBUTE_NORMAL;placeholder.FileIdentity="welcome";placeholder.FileIdentityLength=7;placeholder.Flags=CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
        DWORD processed=0;Check(CfCreatePlaceholders(root.c_str(),&placeholder,1,CF_CREATE_FLAG_STOP_ON_ERROR,&processed),"CfCreatePlaceholders");Check(placeholder.Result,"Placeholder result");
        const auto path=root/L"Welcome to myDrive.txt";
        HANDLE file=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,0,nullptr);
        if(file==INVALID_HANDLE_VALUE)throw HRESULT_FROM_WIN32(GetLastError());
        char buffer[sizeof(content)]{};DWORD read=0;BOOL success=ReadFile(file,buffer,sizeof(content)-1,&read,nullptr);DWORD error=GetLastError();CloseHandle(file);
        if(!success)throw HRESULT_FROM_WIN32(error);
        if(read!=sizeof(content)-1||std::memcmp(buffer,content,read)!=0)throw E_FAIL;
        std::wcout<<L"PASS: registered a real Cloud Files sync root, created a dataless placeholder, and verified hydration on open.\n";exitCode=0;
    }catch(HRESULT result){std::wcerr<<L"Cloud Files spike failed: 0x"<<std::hex<<result<<L". Check that the Windows Cloud Files filter is available on this volume.\n";}
    catch(const std::exception& e){std::cerr<<e.what()<<"\n";}
    if(connected)CfDisconnectSyncRoot(connection);
    if(registered){HRESULT result=CfUnregisterSyncRoot(root.c_str());if(FAILED(result)){std::wcerr<<L"Cleanup could not unregister "<<root<<L"\n";return 2;}}
    // Never enumerate or remove an existing user's sync root. This path was created above.
    std::error_code cleanupError;std::filesystem::remove(root/L"Welcome to myDrive.txt",cleanupError);std::filesystem::remove(root,cleanupError);
    return exitCode;
}
