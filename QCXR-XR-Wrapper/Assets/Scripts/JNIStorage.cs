using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using TMPro;
using UnityEngine;
using UnityEngine.CrashReportHandler;
using UnityEngine.XR.Management;

public class JNIStorage : MonoBehaviour
{
    public static AndroidJavaClass apiClass;
    public static AndroidJavaObject accountObj;
    public static AndroidJavaObject activity;
    public static AndroidJavaObject instancesObj;
    private static string launcherMicrophoneDevice;
    private static AudioClip launcherMicrophoneClip;
    public APIHandler apiHandler;
    public static JNIStorage instance;
    public List<string> supportedVersions;
    public UIHandler uiHandler;
    public TMP_Dropdown instancesDropdown;
    public ConfigHandler configHandler;
    public GameObject instancePrefab;
    public GameObject instanceArray;
    
    public bool connected;
    
    public static void CloseXR()
    {
        XRManagerSettings manager = XRGeneralSettings.Instance?.Manager;
        if (manager == null || manager.activeLoader == null)
            return;

        manager.StopSubsystems();
        manager.DeinitializeLoader();
    }
    
    [RuntimeInitializeOnLoadMethod]
    static void RunOnStart()
    {
        Application.unloading += CloseXR;
    }

    private void Start()
    {
		CrashReportHandler.enableCaptureExceptions = false;
        instance = this;

        // If the user has not granted Microphone permission, don't try to start the clip.
        if (Microphone.devices.Length != 0)
        {
            launcherMicrophoneDevice = Microphone.devices[0];
            launcherMicrophoneClip = Microphone.Start(launcherMicrophoneDevice, true, 1, 44100);
        }

        apiClass = new AndroidJavaClass("pojlib.API");
        instancesObj = apiClass.CallStatic<AndroidJavaObject>("loadAll");
        configHandler.LoadConfig();
        UpdateInstances();
	    apiClass.SetStatic("model", OpenXRFeatureSystemInfo.GetHeadsetName());
        CheckConnection();
    }

    public static bool StopLauncherMicrophone()
    {
        bool released = false;
        string microphoneDevice = launcherMicrophoneDevice;
        System.Exception stopFailure = null;
        if (!string.IsNullOrEmpty(microphoneDevice))
        {
            try
            {
                if (Microphone.IsRecording(microphoneDevice))
                {
                    Microphone.End(microphoneDevice);
                    released = true;
                }
                launcherMicrophoneDevice = null;
            }
            catch (System.Exception exception)
            {
                // Retain the device name so a repeated best-effort release can
                // retry it, and propagate the failure to the aggregate release
                // marker instead of reporting a false success.
                stopFailure = exception;
            }
        }
        else
        {
            launcherMicrophoneDevice = null;
        }

        AudioClip microphoneClip = launcherMicrophoneClip;
        if (microphoneClip != null)
        {
            try
            {
                UnityEngine.Object.Destroy(microphoneClip);
                launcherMicrophoneClip = null;
                released = true;
            }
            catch (System.Exception exception)
            {
                if (stopFailure == null)
                    stopFailure = exception;
                else
                    stopFailure = new AggregateException(stopFailure, exception);
            }
        }
        else
        {
            launcherMicrophoneClip = null;
        }

        if (stopFailure != null)
            throw new InvalidOperationException("Launcher microphone release was incomplete.", stopFailure);
        return released;
    }

    private void FillSupportedVersions(string[] supportedVersionsArray)
    {
        supportedVersions.Clear();
        supportedVersions.AddRange(supportedVersionsArray);
        AndroidJavaObject[] instances = instancesObj.Call<AndroidJavaObject[]>("toArray");
        foreach (var instanceObj in instances)
        {
            string name = instanceObj.Get<string>("instanceName");
            string image = instanceObj.Get<string>("instanceImageURL");
            
            if (!supportedVersions.Contains(name))
            {
                supportedVersions.Add(name);
            }
        }
    }

    public static PojlibInstance GetInstance(string name)
    {
        AndroidJavaObject[] instances = instancesObj.Call<AndroidJavaObject[]>("toArray");
        foreach (var instanceObj in instances)
        {
            PojlibInstance pojlibInstance = PojlibInstance.Parse(instanceObj);
            if (pojlibInstance.instanceName.Equals(name))
            {
                return pojlibInstance;
            }
        }

        return null;
    }

    public void UpdateInstances()
    {
        if (Application.platform != RuntimePlatform.Android) return;
        AndroidJavaClass jc = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
        activity = jc.GetStatic<AndroidJavaObject>("currentActivity");
        uiHandler.ClearDropdowns();
        string[] supportedVersionsArray = apiClass.CallStatic<string[]>("getQCSupportedVersions", activity);
        FillSupportedVersions(supportedVersionsArray);
        uiHandler.UpdateDropdowns(true, supportedVersions);
    }
    
    public void CheckConnection()
    {
        connected = apiClass.CallStatic<bool>("hasConnection", activity);
        if (!connected)
        {
            uiHandler.SetAndShowError("Unable to connect to Microsoft servers, are you offline? Some features may not work properly!");
        }
    }

    public async void FixFilePermissions()
    {
        bool result = apiClass.CallStatic<bool>("fixDataPermissions");
        if (!result)
        {
            uiHandler.SetAndShowError("Fixing data permissions failed. Please report this.");
        }
        else
        {
            uiHandler.SetAndShowError("Fixing data permissions succeeded!");
        }
    }
}
